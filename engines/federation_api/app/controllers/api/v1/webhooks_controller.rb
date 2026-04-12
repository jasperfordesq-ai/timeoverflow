# Federation API: Webhook receiver endpoint.
#
# Receives webhook events from federation partners (e.g., Nexus).
# Validates HMAC-SHA256 signatures and dispatches events to handlers.
#
module Api
  module V1
    class WebhooksController < BaseController
      # Skip standard API key auth for webhooks — use HMAC signature instead
      skip_before_action :authenticate_api_key!
      skip_before_action :enforce_rate_limit!
      before_action :enforce_webhook_rate_limit!
      before_action :verify_webhook_signature!

      # POST /api/v1/webhooks/receive
      def receive
        event_type = params[:event]
        payload = params[:data].respond_to?(:to_unsafe_h) ? params[:data].to_unsafe_h : (params[:data].respond_to?(:to_h) ? params[:data].to_h : {})
        partner_id = params[:partner_id] || params[:tenant_id]

        if event_type.blank?
          return respond_with_error(I18n.t("federation_api.errors.missing_event", default: "Missing required field: event"), status: :bad_request)
        end

        # Use the partner verified by HMAC signature (avoids double-lookup divergence).
        partner = @verified_partner || FederationPartner.find_by(id: partner_id)
        unless partner
          return respond_with_error(I18n.t("federation_api.errors.unknown_partner", default: "Unknown partner"), status: :not_found)
        end

        # Per-partner rate limit (in addition to per-IP limit in before_action)
        enforce_partner_rate_limit!(partner)
        return if performed?

        # Allow partnership status-change events from non-active partners (e.g., a
        # suspended partner sending "partnership.activated" to reactivate itself).
        # All other events require an active partner.
        partnership_events = %w[partnership.activated partnership.approved partnership.suspended partnership.rejected partnership.terminated partnership.level_changed]
        unless partner.active? || partnership_events.include?(event_type)
          return respond_with_error(I18n.t("federation_api.errors.inactive_partner", default: "Inactive partner"), status: :forbidden)
        end

        # Replay attack prevention: derive a deterministic nonce from the request.
        # If a partner sends X-Federation-Nonce we use that; otherwise we derive
        # one from SHA256(body + timestamp) so the same replayed request always
        # produces the same nonce and is rejected idempotently.
        nonce = derive_request_nonce
        if nonce.present? && FederationWebhookLog.exists?(federation_partner: partner, request_nonce: nonce)
          return respond_with_data({ received: true, event: event_type, duplicate: true })
        end

        # Log the incoming webhook
        log = FederationWebhookLog.create!(
          federation_partner: partner,
          event_type: event_type,
          direction: "inbound",
          status: "pending",
          request_nonce: nonce,
          payload: { event: event_type, partner_id: partner_id, data: payload }
        )

        begin
          handle_event(event_type, payload, partner)
          log.update!(status: "success")
          respond_with_data({ received: true, event: event_type })
        rescue => e
          # Log full details server-side; store class + message in the log record
          # (backtrace is in the Rails log, not exposed to the calling partner).
          Rails.logger.error("[Federation::Webhook] Processing failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
          log.update!(
            status: "failed",
            response_body: "#{e.class}: #{e.message}"
          )
          respond_with_error(I18n.t("federation_api.errors.webhook_processing_failed", default: "Webhook processing failed"), status: :internal_server_error)
        end
      end

      private

      # Sliding-window rate limit for webhooks by IP (not by API key since webhooks skip auth).
      def enforce_webhook_rate_limit!
        ip = request.remote_ip
        limit = ENV.fetch("FEDERATION_WEBHOOK_IP_RATE_LIMIT", "200").to_i
        estimated = sliding_window_read("federation_webhook_rate:#{ip}")

        if estimated > limit
          respond_with_error(I18n.t("federation_api.errors.webhook_rate_limit_exceeded", default: "Rate limit exceeded"), status: :too_many_requests)
        end
      end

      def verify_webhook_signature!
        # Accept either Nexus-style (X-Federation-Signature) or simple (X-Webhook-Signature)
        signature = request.headers["X-Federation-Signature"] || request.headers["X-Webhook-Signature"]
        return respond_with_error(I18n.t("federation_api.errors.missing_signature", default: "Missing signature"), status: :unauthorized) if signature.blank?

        body = request.raw_post
        return respond_with_error(I18n.t("federation_api.errors.empty_request_body", default: "Empty request body"), status: :bad_request) if body.blank?

        # Reject oversized payloads to prevent memory exhaustion (max 1 MB).
        max_body_size = ENV.fetch("FEDERATION_WEBHOOK_MAX_BODY_SIZE", "1048576").to_i
        if body.bytesize > max_body_size
          return respond_with_error(I18n.t("federation_api.errors.request_body_too_large", default: "Request body too large"), status: :payload_too_large)
        end

        # H5: Limit JSON nesting depth to prevent stack exhaustion attacks.
        parsed = JSON.parse(body, max_nesting: 10) rescue nil
        partner_id = parsed&.dig("partner_id") || parsed&.dig("tenant_id")
        partner = FederationPartner.find_by(id: partner_id)

        # Use generic error message for both unknown partner and invalid signature
        # to prevent partner-ID enumeration via differential error responses.
        return respond_with_error(I18n.t("federation_api.errors.invalid_signature", default: "Invalid signature"), status: :unauthorized) unless partner

        # Fix #2: Reject partners with no webhook_secret — HMAC with empty key
        # can be forged by anyone who knows the request body format.
        if partner.webhook_secret.blank?
          Rails.logger.error("[Federation::Webhook] Partner #{partner.id} has no webhook_secret configured")
          return respond_with_error(I18n.t("federation_api.errors.partner_webhook_not_configured", default: "Partner webhook not configured"), status: :unauthorized)
        end

        # Collect all valid secrets (supports zero-downtime rotation).
        # During a rotation window both the current and next secret are accepted.
        valid_secrets = partner.valid_webhook_secrets

        # Try Nexus HMAC format first: METHOD\nPATH\nTIMESTAMP\nBODY
        timestamp = request.headers["X-Federation-Timestamp"]
        if timestamp.present?
          string_to_sign = [
            request.method.upcase,
            request.fullpath,
            timestamp,
            body
          ].join("\n")

          matched = valid_secrets.any? do |secret|
            expected = OpenSSL::HMAC.hexdigest("SHA256", secret, string_to_sign)
            ActiveSupport::SecurityUtils.secure_compare(signature, expected)
          end

          if matched
            # Check timestamp freshness (5 minute window)
            if (Time.current.to_i - timestamp.to_i).abs > 300
              respond_with_error(I18n.t("federation_api.errors.webhook_timestamp_expired", default: "Webhook timestamp expired"), status: :unauthorized)
              return
            end
            @verified_partner = partner
            return # signature valid, timestamp fresh
          end
          # Nexus format signature didn't match — don't fall through, reject immediately
          respond_with_error(I18n.t("federation_api.errors.invalid_signature", default: "Invalid signature"), status: :unauthorized)
          return
        end

        # Fallback: simple body-only signature (TO native webhooks).
        # Require a timestamp header on this path too — without it there is
        # no replay protection, so reject the request outright.
        simple_ts = request.headers["X-Webhook-Timestamp"]
        if simple_ts.blank?
          respond_with_error(I18n.t("federation_api.errors.missing_timestamp", default: "Missing timestamp"), status: :unauthorized)
          return
        end
        if (Time.current.to_i - simple_ts.to_i).abs > 300
          respond_with_error(I18n.t("federation_api.errors.webhook_timestamp_expired", default: "Webhook timestamp expired"), status: :unauthorized)
          return
        end

        matched_simple = valid_secrets.any? do |secret|
          expected_simple = OpenSSL::HMAC.hexdigest("SHA256", secret, body)
          ActiveSupport::SecurityUtils.secure_compare(signature, expected_simple)
        end

        unless matched_simple
          respond_with_error(I18n.t("federation_api.errors.invalid_signature", default: "Invalid signature"), status: :unauthorized)
          return
        end

        @verified_partner = partner
        # Increment IP rate counter only after successful authentication
        # to prevent unauthenticated requests from exhausting the budget.
        sliding_window_increment("federation_webhook_rate:#{request.remote_ip}")
      end

      # Derive a deterministic nonce for replay prevention.
      # Uses the explicit header if provided, otherwise SHA256(body + timestamp)
      # so identical replayed requests always produce the same nonce.
      def derive_request_nonce
        explicit = request.headers["X-Federation-Nonce"] || request.headers["X-Webhook-Nonce"]
        return explicit if explicit.present?

        timestamp = request.headers["X-Federation-Timestamp"] || request.headers["X-Webhook-Timestamp"]
        body = request.raw_post
        return nil if body.blank? && timestamp.blank?

        # Include partner_id to prevent nonce collisions when two partners
        # send identical payloads at the same second.
        partner_id = @verified_partner&.id || "unknown"
        Digest::SHA256.hexdigest("#{partner_id}:#{body}:#{timestamp}")
      end

      # Per-partner rate limit — supplements the per-IP limit. Prevents a single
      # partner from flooding the webhook endpoint across multiple source IPs.
      def enforce_partner_rate_limit!(partner)
        limit = ENV.fetch("FEDERATION_WEBHOOK_PARTNER_RATE_LIMIT", "100").to_i
        sliding_window_increment("federation_webhook_partner:#{partner.id}")
        estimated = sliding_window_read("federation_webhook_partner:#{partner.id}")

        if estimated > limit
          respond_with_error(I18n.t("federation_api.errors.partner_rate_limit_exceeded", default: "Partner rate limit exceeded"), status: :too_many_requests)
        end
      end

      # Read-only sliding-window estimate (does not increment the counter).
      def sliding_window_read(prefix)
        now = Time.current.to_i
        current_window = now / 60
        previous_window = current_window - 1
        elapsed_fraction = (now % 60) / 60.0

        current_key  = "#{prefix}:#{current_window}"
        previous_key = "#{prefix}:#{previous_window}"

        current_count = Rails.cache.read(current_key).to_i
        previous_count = Rails.cache.read(previous_key).to_i

        (previous_count * (1 - elapsed_fraction)) + current_count
      end

      # Increment-and-read sliding-window counter.
      def sliding_window_increment(prefix)
        now = Time.current.to_i
        current_window = now / 60
        current_key = "#{prefix}:#{current_window}"
        Rails.cache.increment(current_key, 1, expires_in: 2.minutes)
      end

      def handle_event(event_type, payload, partner)
        case event_type
        when "partnership.activated", "partnership.approved"
          # Nexus sends "partnership.approved"; TO also accepts "partnership.activated".
          if partner.status == "terminated"
            Rails.logger.warn("[Federation] Rejected reactivation of terminated partner #{partner.id}")
          else
            partner.update!(status: "active")
          end
        when "partnership.suspended", "partnership.rejected"
          partner.update!(status: "suspended")
        when "partnership.terminated"
          partner.update!(status: "terminated")
        when "partnership.level_changed"
          level = payload["level"].to_i
          # Fix #11: Only allow level decreases via webhook (downgrades).
          # Upgrades require admin approval on both sides — a partner should
          # not be able to self-promote to level 4 (Integrated) by sending
          # a webhook. Downgrades (e.g., suspending economic access) are
          # permitted unilaterally since they reduce privilege.
          if level.between?(1, 4)
            if level <= partner.partnership_level
              partner.update!(partnership_level: level)
              Rails.logger.info("[Federation] Partner #{partner.id} level changed to #{level} (downgrade/same)")
            else
              Rails.logger.warn("[Federation] Rejected level upgrade attempt for partner #{partner.id}: #{partner.partnership_level} → #{level} (requires admin approval)")
            end
          else
            Rails.logger.warn("[Federation] Invalid partnership level in webhook: #{level}")
          end
        when "transaction.requested", "transaction.created"
          # Nexus sends "transaction.created"; TO also accepts "transaction.requested".
          Federation::TransferHandler.handle_inbound_request(partner, payload)
        when "transaction.cancelled"
          if payload["external_transaction_id"].blank?
            Rails.logger.warn("[Federation::Webhook] transaction.cancelled missing external_transaction_id from partner #{partner.id}")
            return # Cannot identify which transaction to cancel
          end
          fed_txn = FederationTransaction.find_by(
            external_transaction_id: payload["external_transaction_id"],
            federation_partner: partner
          )
          # Fix #7: Only cancel if still pending — cancel! now raises on
          # completed/cancelled records so we guard here instead of relying
          # on a bare &.cancel! to silently corrupt accounting.
          if fed_txn&.pending?
            fed_txn.cancel!(reason: payload["reason"])
          elsif fed_txn
            Rails.logger.warn("[Federation::Webhook] Ignoring cancellation for #{fed_txn.status} transaction #{fed_txn.id}")
          end
        when "message.sent", "message.received"
          # A partner sent a message destined for a local member.
          handle_inbound_message(partner, payload)
        when "member.opted_in"
          Rails.logger.info("[Federation] Remote member opted in: #{payload['member_id']} on partner #{partner.id}")
        when "member.opted_out"
          Rails.logger.info("[Federation] Remote member opted out: #{payload['member_id']} on partner #{partner.id}")
        when "listing.shared"
          Rails.logger.info("[Federation] Partner #{partner.id} shared listing: #{payload['listing_id']}")
        when "connection.requested", "connection.accepted"
          Rails.logger.info("[Federation] Connection event from partner #{partner.id}: #{event_type}")
        when "health_check"
          partner.record_success!
        else
          Rails.logger.info("[Federation] Unhandled webhook event: #{event_type}")
        end
      end

      def handle_inbound_message(partner, payload)
        # Idempotency
        ext_id = payload["external_message_id"] || payload["message_id"]
        if ext_id.present?
          existing = FederationMessage.find_by(
            federation_partner: partner,
            external_message_id: ext_id
          )
          return existing if existing
        end

        # Resolve recipient
        org_id = payload["organization_id"] || payload["local_organization_id"]
        org = Organization.find_by(id: org_id)
        member = nil

        if payload["recipient_id"].present? && org
          member = org.members.active.find_by(id: payload["recipient_id"]) ||
                   org.members.active.find_by(member_uid: payload["recipient_id"])
        elsif payload["local_member_id"].present?
          member = Member.find_by(id: payload["local_member_id"], active: true)
          org ||= member&.organization
        end

        unless member && org
          raise ArgumentError, "Could not resolve message recipient for webhook payload (org_id=#{org_id}, recipient_id=#{payload['recipient_id']}, local_member_id=#{payload['local_member_id']})"
        end

        msg = FederationMessage.create!(
          federation_partner: partner,
          organization_id: org.id,
          local_member_id: member.id,
          remote_user_identifier: payload["sender_id"] || payload["remote_user_identifier"] || "unknown",
          external_message_id: ext_id,
          direction: "inbound",
          subject: payload["subject"],
          body: payload["body"] || payload["message"] || "",
          status: "delivered",
          delivered_at: Time.current,
          metadata: {
            "sender_name" => payload["sender_name"],
            "via_webhook" => true
          }.compact
        )

        # Notify the local member about the received message.
        Federation::NotificationService.notify(
          member: member,
          event_type: :message_received,
          data: { sender_name: payload["sender_name"] || msg.remote_user_identifier, subject: msg.subject, body: msg.body, partner_name: partner.name }
        )
      end
    end
  end
end

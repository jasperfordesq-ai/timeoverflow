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
        payload = params[:data] || {}
        partner_id = params[:partner_id] || params[:tenant_id]

        partner = FederationPartner.find_by(id: partner_id)
        unless partner&.active?
          return respond_with_error("Unknown or inactive partner", status: :not_found)
        end

        # Log the incoming webhook
        log = FederationWebhookLog.create!(
          federation_partner: partner,
          event_type: event_type,
          direction: "inbound",
          status: "pending",
          payload: { event: event_type, partner_id: partner_id, data: payload.to_h }
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
          respond_with_error("Webhook processing failed")
        end
      end

      private

      # Rate limit webhooks by IP (not by API key since webhooks skip auth)
      def enforce_webhook_rate_limit!
        ip = request.remote_ip
        cache_key = "federation_webhook_rate:#{ip}:#{Time.current.to_i / 60}"
        count = Rails.cache.increment(cache_key, 1, expires_in: 2.minutes) || 1

        if count > 200 # webhooks get higher limit than API calls
          render json: { success: false, error: "Rate limit exceeded" }, status: :too_many_requests
        end
      end

      def verify_webhook_signature!
        # Accept either Nexus-style (X-Federation-Signature) or simple (X-Webhook-Signature)
        signature = request.headers["X-Federation-Signature"] || request.headers["X-Webhook-Signature"]
        return respond_with_error("Missing signature", status: :unauthorized) if signature.blank?

        body = request.raw_post
        parsed = JSON.parse(body) rescue nil
        partner_id = parsed&.dig("partner_id") || parsed&.dig("tenant_id")
        partner = FederationPartner.find_by(id: partner_id)

        return respond_with_error("Unknown partner", status: :unauthorized) unless partner

        # Fix #2: Reject partners with no webhook_secret — HMAC with empty key
        # can be forged by anyone who knows the request body format.
        if partner.webhook_secret.blank?
          Rails.logger.error("[Federation::Webhook] Partner #{partner.id} has no webhook_secret configured")
          return respond_with_error("Partner webhook not configured", status: :unauthorized)
        end

        # Try Nexus HMAC format first: METHOD\nPATH\nTIMESTAMP\nBODY
        timestamp = request.headers["X-Federation-Timestamp"]
        if timestamp.present?
          string_to_sign = [
            request.method.upcase,
            request.fullpath,
            timestamp,
            body
          ].join("\n")
          expected = OpenSSL::HMAC.hexdigest("SHA256", partner.webhook_secret.to_s, string_to_sign)

          if ActiveSupport::SecurityUtils.secure_compare(signature, expected)
            # Check timestamp freshness (5 minute window)
            if (Time.current.to_i - timestamp.to_i).abs > 300
              respond_with_error("Webhook timestamp expired", status: :unauthorized)
              return
            end
            return # signature valid, timestamp fresh
          end
          # Nexus format signature didn't match — don't fall through, reject immediately
          respond_with_error("Invalid signature", status: :unauthorized)
          return
        end

        # Fallback: simple body-only signature (TO native webhooks)
        expected_simple = OpenSSL::HMAC.hexdigest("SHA256", partner.webhook_secret.to_s, body)
        unless ActiveSupport::SecurityUtils.secure_compare(signature, expected_simple)
          respond_with_error("Invalid signature", status: :unauthorized)
        end
      end

      def handle_event(event_type, payload, partner)
        case event_type
        when "partnership.activated"
          partner.update!(status: "active")
        when "partnership.suspended"
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
        when "transaction.requested"
          # A remote user wants to initiate a transfer — handle idempotently.
          # handle_inbound_request now checks for existing records before
          # entering the transaction block, returning the existing record
          # rather than raising RecordNotUnique (which caused 500s on retry).
          Federation::TransferHandler.handle_inbound_request(partner, payload)
        when "transaction.cancelled"
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
        when "health_check"
          partner.record_success!
        else
          Rails.logger.info("[Federation] Unhandled webhook event: #{event_type}")
        end
      end
    end
  end
end

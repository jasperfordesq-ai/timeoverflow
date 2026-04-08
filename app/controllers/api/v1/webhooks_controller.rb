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
          payload: params.to_unsafe_h.except(:controller, :action)
        )

        begin
          handle_event(event_type, payload, partner)
          log.update!(status: "success")
          respond_with_data({ received: true, event: event_type })
        rescue => e
          log.update!(status: "failed", response_body: e.message)
          respond_with_error("Webhook processing failed: #{e.message}")
        end
      end

      private

      def verify_webhook_signature!
        # Accept either Nexus-style (X-Federation-Signature) or simple (X-Webhook-Signature)
        signature = request.headers["X-Federation-Signature"] || request.headers["X-Webhook-Signature"]
        return respond_with_error("Missing signature", status: :unauthorized) if signature.blank?

        body = request.raw_post
        partner_id = JSON.parse(body)["partner_id"] || JSON.parse(body)["tenant_id"] rescue nil
        partner = FederationPartner.find_by(id: partner_id)

        return respond_with_error("Unknown partner", status: :unauthorized) unless partner

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
              return respond_with_error("Timestamp expired", status: :unauthorized)
            end
            return # signature valid
          end
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
          partner.update!(partnership_level: payload["level"].to_i) if payload["level"]
        when "transaction.requested"
          # A remote user wants to initiate a transfer — queue for processing
          Federation::TransferHandler.handle_inbound_request(partner, payload)
        when "transaction.cancelled"
          fed_txn = FederationTransaction.find_by(
            external_transaction_id: payload["external_transaction_id"],
            federation_partner: partner
          )
          fed_txn&.cancel!(reason: payload["reason"])
        when "health_check"
          partner.record_success!
        else
          Rails.logger.info("[Federation] Unhandled webhook event: #{event_type}")
        end
      end
    end
  end
end

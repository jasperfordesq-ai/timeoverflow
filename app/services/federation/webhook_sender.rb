# Sends webhook events to federation partners.
#
# Signs payloads with HMAC-SHA256 using the partner's webhook_secret.
# Logs all delivery attempts for audit purposes.
#
module Federation
  class WebhookSender
    TIMEOUT = 10 # seconds

    # Send a webhook synchronously (for testing or critical events)
    def self.send_now(partner:, event:, payload: {})
      new(partner: partner, event: event, payload: payload).deliver
    end

    # Queue a webhook for async delivery via Sidekiq.
    # Pass fed_txn_id for "transaction.requested" outbound events so
    # WebhookDeliveryJob can call complete! on confirmed delivery.
    def self.send_async(partner:, event:, payload: {}, fed_txn_id: nil)
      Federation::WebhookDeliveryJob.perform_later(
        partner.id,
        event,
        payload.as_json,
        fed_txn_id
      )
    rescue => e
      Rails.logger.error("[Federation] Failed to queue webhook: #{e.message}")
    end

    def initialize(partner:, event:, payload: {})
      @partner = partner
      @event = event
      @payload = payload
    end

    def deliver
      return unless @partner.webhook_url.present?

      body = build_body
      signature = sign(body)

      log = FederationWebhookLog.create!(
        federation_partner: @partner,
        event_type: @event,
        direction: "outbound",
        status: "pending",
        payload: @payload
      )

      begin
        uri = URI(@partner.webhook_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["X-Webhook-Signature"] = signature
        request["X-Federation-Signature"] = signature
        request["X-Webhook-Event"] = @event
        request["User-Agent"] = "TimeOverflow-Federation/1.0"
        request.body = body

        response = http.request(request)

        log.update!(
          status: response.code.to_i < 300 ? "success" : "failed",
          response_code: response.code.to_i,
          response_body: response.body&.truncate(1000)
        )

        if response.code.to_i < 300
          @partner.record_success!
        else
          @partner.record_failure!
        end

        response
      rescue => e
        log.update!(status: "failed", response_body: e.message)
        @partner.record_failure!
        raise
      end
    end

    private

    def build_body
      {
        event: @event,
        timestamp: Time.current.iso8601,
        partner_id: @partner.id,
        platform: "timeoverflow",
        data: @payload
      }.to_json
    end

    def sign(body)
      OpenSSL::HMAC.hexdigest("SHA256", @partner.webhook_secret.to_s, body)
    end
  end
end

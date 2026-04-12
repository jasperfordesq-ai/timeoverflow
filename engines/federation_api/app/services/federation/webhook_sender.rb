# Sends webhook events to federation partners.
#
# Signs payloads with HMAC-SHA256 using the partner's webhook_secret.
# Logs all delivery attempts for audit purposes.
#
require "resolv"
require "ipaddr"

module Federation
  class WebhookSender
    # Read timeout from engine config (set via FEDERATION_WEBHOOK_TIMEOUT env var).
    # Falls back to 10 seconds if config is unavailable.
    def self.timeout
      Rails.application.config.federation.webhook_timeout
    rescue
      10
    end

    # M9: Cap the size of payload stored in webhook logs to avoid bloating the DB.
    # Full payload is always sent over the wire — this only affects the log record.
    MAX_LOG_PAYLOAD_SIZE = ENV.fetch("FEDERATION_MAX_LOG_PAYLOAD_SIZE", "10000").to_i

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
      Rails.logger.fatal("[Federation] Failed to queue webhook for partner #{partner.id} event=#{event}: #{e.class}: #{e.message}")
      raise
    end

    def initialize(partner:, event:, payload: {})
      @partner = partner
      @event = event
      @payload = payload
    end

    def deliver
      return unless @partner.webhook_url.present?

      validate_url_safety!(@partner.webhook_url)

      body = build_body
      signature = sign(body)

      log = FederationWebhookLog.create!(
        federation_partner: @partner,
        event_type: @event,
        direction: "outbound",
        status: "pending",
        payload: log_safe_payload  # M9: truncated/redacted before storage
      )

      begin
        uri = URI(@partner.webhook_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        timeout = self.class.timeout
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)

        timestamp = Time.current.to_i.to_s

        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["X-Webhook-Signature"] = signature
        request["X-Federation-Signature"] = signature
        request["X-Webhook-Timestamp"] = timestamp
        request["X-Federation-Timestamp"] = timestamp
        request["X-Webhook-Event"] = @event
        request["User-Agent"] = "TimeOverflow-Federation/1.0"
        request.body = body

        response = http.request(request)

        log.update!(
          status: response.code.to_i < 300 ? "success" : "failed",
          response_code: response.code.to_i,
          response_body: response.body&.truncate(ENV.fetch("FEDERATION_MAX_RESPONSE_LOG_SIZE", "1000").to_i)
        )

        if response.code.to_i < 300
          @partner.record_success!
        else
          @partner.record_failure!
        end

        response
      rescue => e
        log.update!(status: "failed", response_body: e.message)
        # Do NOT call record_failure! here — network errors will be retried by
        # WebhookDeliveryJob and each retry would increment the counter. The job's
        # exhaustion handler records the failure once after all retries are spent.
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
      # L1: Explicit blank? guard — .to_s on nil produces an empty key, allowing
      # HMAC forgery by anyone who knows the request format. Fail loudly instead.
      if @partner.webhook_secret.blank?
        raise ArgumentError, "webhook_secret is blank for partner #{@partner.id} — cannot sign webhook"
      end
      OpenSSL::HMAC.hexdigest("SHA256", @partner.webhook_secret, body)
    end

    # SSRF protection: reject URLs that resolve to private/loopback addresses.
    PRIVATE_RANGES = [
      IPAddr.new("127.0.0.0/8"),
      IPAddr.new("10.0.0.0/8"),
      IPAddr.new("172.16.0.0/12"),
      IPAddr.new("192.168.0.0/16"),
      IPAddr.new("169.254.0.0/16"),
      IPAddr.new("::1/128"),
      IPAddr.new("fc00::/7")
    ].freeze

    def validate_url_safety!(url)
      uri = URI.parse(url)
      raise ArgumentError, "Webhook URL has no host" unless uri.host

      addresses = Resolv.getaddresses(uri.host)
      raise ArgumentError, "Cannot resolve webhook host: #{uri.host}" if addresses.empty?

      addresses.each do |addr|
        ip = IPAddr.new(addr)
        if PRIVATE_RANGES.any? { |range| range.include?(ip) }
          raise ArgumentError, "Webhook URL resolves to private/loopback address (#{addr}) — SSRF blocked"
        end
      end
    end

    # M9: Return a sanitised copy of the payload safe for DB log storage.
    # Large or sensitive fields are redacted; essential identifiers are kept.
    def log_safe_payload
      payload_json = @payload.to_json
      return @payload if payload_json.bytesize <= MAX_LOG_PAYLOAD_SIZE

      {
        _truncated: true,
        _original_size_bytes: payload_json.bytesize,
        _note: "Payload exceeded #{MAX_LOG_PAYLOAD_SIZE} bytes — only key fields stored",
        event: @event,
        partner_id: @partner.id,
        federation_transaction_id: @payload["federation_transaction_id"] || @payload[:federation_transaction_id],
        external_transaction_id: @payload["external_transaction_id"] || @payload[:external_transaction_id]
      }
    end
  end
end

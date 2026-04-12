# Calls a federation partner's API.
# Supports both GET (fetch data) and POST (send data) operations.
#
# Uses the partner's protocol adapter for:
#   - Endpoint mapping (action → URL path)
#   - Data transformation (outbound/inbound)
#   - Response unwrapping (protocol-specific envelopes)
#   - Content negotiation (Accept/Content-Type headers)
#
# Authentication: Bearer token via the partner's api_key_hash field.
#
require "resolv"
require "ipaddr"

module Federation
  class PartnerApiClient
    TIMEOUT = 10
    MAX_RESPONSE_SIZE = 10_000_000  # 10 MB

    def initialize(partner:)
      @partner = partner
      @adapter = partner.adapter
      raise ArgumentError, "Partner has no API endpoint" if @partner.api_endpoint.blank?
    end

    # --- High-level API methods (adapter-aware) ---

    # Fetch listings from the partner's API.
    def fetch_listings(params = {})
      result = get(@adapter.map_endpoint("listings"), params.compact)
      transform_collection(result, :transform_inbound_listings)
    end

    # Fetch a single listing.
    def fetch_listing(id)
      result = get(@adapter.map_endpoint("listing", id: id))
      transform_single(result, :transform_inbound_listing)
    end

    # Fetch members from the partner.
    def fetch_members(params = {})
      result = get(@adapter.map_endpoint("members"), params.compact)
      transform_collection(result, :transform_inbound_members)
    end

    # Fetch a single member.
    def fetch_member(id)
      result = get(@adapter.map_endpoint("member", id: id))
      transform_single(result, :transform_inbound_member)
    end

    # Health check the partner.
    # Tries the standard /health endpoint first. If that fails (404),
    # falls back to sending a health_check event to the webhook receiver,
    # which Nexus and other partners support.
    def health_check
      result = health_probe(@adapter.map_endpoint("health"))
      if result["success"] == false && result["error"]&.include?("404")
        # Fallback: POST health_check event to the webhook/receive endpoint
        fallback = post(@adapter.map_endpoint("receive"), {
          event: "health_check",
          timestamp: Time.current.iso8601,
          platform: "timeoverflow",
          data: {}
        })
        # If fallback succeeded, undo the failure from the 404 probe
        @partner.record_success! if fallback["success"] != false
        fallback
      else
        result
      end
    end

    # Send a generic webhook event to the partner's receiver endpoint.
    # Used by Hub controllers that need to query partner data via events
    # (e.g., members.list, listings.list) without going through WebhookSender.
    def send_event(event, data = {})
      endpoint = @adapter.map_endpoint("receive")
      post(endpoint, {
        event: event,
        timestamp: Time.current.iso8601,
        platform: "timeoverflow",
        data: data
      })
    end

    # Send a message to the partner's API.
    def post_message(payload)
      transformed = @adapter.transform_outbound_message(payload)
      endpoint = @adapter.map_endpoint("receive")
      post(endpoint, {
        event: "message.sent",
        timestamp: Time.current.iso8601,
        platform: "timeoverflow",
        data: transformed
      })
    end

    # Send a transfer/transaction to the partner's API.
    def post_transfer(payload)
      transformed = @adapter.transform_outbound_transfer(payload)
      endpoint = @adapter.map_endpoint("transfers")
      method = @adapter.map_http_method("transfers", "POST")
      if method == "POST"
        post(endpoint, transformed)
      else
        # Support PATCH/PUT for protocols that use them
        request_with_method(method, endpoint, transformed)
      end
    end

    private

    # --- Transport layer ---

    # Like get() but does NOT record failure on error — used for probing
    # endpoints that may not exist (e.g., /health before fallback to /receive).
    def health_probe(path)
      uri = build_browse_uri(path)
      request = Net::HTTP::Get.new(uri)
      set_headers(request)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      response = http.request(request)

      if response.code.to_i < 300
        @partner.record_success!
        JSON.parse(response.body)
      else
        { "success" => false, "error" => "Partner returned #{response.code}" }
      end
    rescue => e
      { "success" => false, "error" => e.message }
    end

    def get(path, params = {})
      uri = build_browse_uri(path)
      uri.query = URI.encode_www_form(params) if params.any?

      request = Net::HTTP::Get.new(uri)
      set_headers(request)

      execute(uri, request)
    end

    def post(path, data = {})
      uri = build_uri(path)

      request = Net::HTTP::Post.new(uri)
      set_headers(request)
      request["Content-Type"] = @adapter.content_type
      request.body = data.to_json

      execute(uri, request)
    end

    def request_with_method(method, path, data = {})
      uri = build_uri(path)
      request_class = case method.to_s.upcase
                      when "POST"   then Net::HTTP::Post
                      when "PATCH"  then Net::HTTP::Patch
                      when "PUT"    then Net::HTTP::Put
                      when "DELETE" then Net::HTTP::Delete
                      else
                        Rails.logger.warn("[Federation::PartnerApiClient] Unknown HTTP method '#{method}', defaulting to POST")
                        Net::HTTP::Post
                      end
      request = request_class.new(uri)
      set_headers(request)
      request["Content-Type"] = @adapter.content_type
      request.body = data.to_json unless method.to_s.upcase == "DELETE"

      execute(uri, request)
    end

    # Build URI for browsing/GET requests — uses browse_base_url if set,
    # otherwise falls back to api_endpoint.
    def build_browse_uri(path)
      base = @partner.browse_base_url.presence || @partner.api_endpoint
      URI("#{base}#{path}")
    end

    # Build URI for webhook/POST requests — always uses api_endpoint.
    def build_uri(path)
      URI("#{@partner.api_endpoint}#{path}")
    end

    def set_headers(request)
      request["Authorization"] = "Bearer #{@partner.api_key_hash}" if @partner.api_key_hash.present?
      request["User-Agent"] = "TimeOverflow-Federation/#{FederationApi::VERSION}"
      request["Accept"] = @adapter.content_type

      # Protocol-specific extra headers
      @adapter.extra_headers.each { |k, v| request[k] = v }
    end

    def execute(uri, request)
      validate_url_safety!(uri.to_s)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT

      response = http.request(request)

      if response.code.to_i < 300
        if response.body && response.body.bytesize > MAX_RESPONSE_SIZE
          @partner.record_failure!
          return { "success" => false, "error" => "Response too large (#{response.body.bytesize} bytes)" }
        end
        if response.body && response.body.bytesize > 1_000_000
          Rails.logger.warn("[Federation::PartnerApiClient] Large response body from #{@partner.name}: #{response.body.bytesize} bytes (>1MB) — skipping JSON parse")
          return { "success" => false, "error" => "Response body too large to parse (#{response.body.bytesize} bytes)" }
        end
        @partner.record_success!
        JSON.parse(response.body)
      else
        @partner.record_failure!
        { "success" => false, "error" => "Partner returned #{response.code}" }
      end
    rescue => e
      @partner.record_failure!
      Rails.logger.error("[Federation::PartnerApiClient] Request to #{@partner.name} failed: #{e.class}: #{e.message}")
      { "success" => false, "error" => e.message }
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
      raise ArgumentError, "URL has no host" unless uri.host

      begin
        addresses = Resolv.getaddresses(uri.host)
      rescue Resolv::ResolvError, Resolv::ResolvTimeout => e
        raise ArgumentError, "DNS resolution failed for host #{uri.host}: #{e.class}: #{e.message}"
      end
      raise ArgumentError, "Cannot resolve host: #{uri.host}" if addresses.empty?

      addresses.each do |addr|
        ip = IPAddr.new(addr)
        if PRIVATE_RANGES.any? { |range| range.include?(ip) }
          raise ArgumentError, "URL resolves to private/loopback address (#{addr}) — SSRF blocked"
        end
      end
    end

    # --- Response transformation helpers ---

    def transform_collection(result, method)
      if result.is_a?(Hash) && result["success"] != false
        data = @adapter.unwrap_response(result)
        data = @adapter.send(method, data) if data.is_a?(Array)
        result.merge("data" => data)
      else
        result
      end
    end

    def transform_single(result, method)
      if result.is_a?(Hash) && result["success"] != false
        data = @adapter.unwrap_response(result)
        data = @adapter.send(method, data) if data.is_a?(Hash)
        result.merge("data" => data)
      else
        result
      end
    end
  end
end

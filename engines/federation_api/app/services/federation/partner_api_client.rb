# Fetches data from a federation partner's API.
# This is the reverse direction — calling OUT to a partner to read their data.
#
module Federation
  class PartnerApiClient
    TIMEOUT = 10
    MAX_RESPONSE_SIZE = 10_000_000  # 10 MB

    def initialize(partner:)
      @partner = partner
      raise ArgumentError, "Partner has no API endpoint" if @partner.api_endpoint.blank?
    end

    # Fetch listings from the partner's API.
    def fetch_listings(params = {})
      get("/listings", params.compact)
    end

    # Fetch a single listing.
    def fetch_listing(id)
      get("/listings/#{id}")
    end

    # Fetch members from the partner.
    def fetch_members(params = {})
      get("/members", params.compact)
    end

    # Fetch a single member.
    def fetch_member(id)
      get("/members/#{id}")
    end

    # Health check the partner.
    def health_check
      get("/health")
    end

    private

    def get(path, params = {})
      uri = URI("#{@partner.api_endpoint}#{path}")
      uri.query = URI.encode_www_form(params) if params.any?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT

      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@partner.api_key_hash}" if @partner.api_key_hash.present?
      request["User-Agent"] = "TimeOverflow-Federation/#{FederationApi::VERSION}"
      request["Accept"] = "application/json"

      response = http.request(request)

      if response.code.to_i < 300
        if response.body && response.body.bytesize > MAX_RESPONSE_SIZE
          @partner.record_failure!
          return { "success" => false, "error" => "Response too large (#{response.body.bytesize} bytes)" }
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
  end
end

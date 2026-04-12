# OAuth2 client-credentials grant for Komunitin authentication.
#
# Komunitin uses standard OAuth2 client_credentials flow.
# Tokens are cached in the FederationPartner metadata column
# and refreshed automatically when expired.
#
# Required partner.metadata keys:
#   - oauth_token_url   (e.g., "https://auth.komunitin.org/token")
#   - oauth_client_id   (application client ID)
# The client_secret is stored in partner.api_key_hash (encrypted field).
#
require "net/http"
require "uri"
require "json"

module Federation
  module Adapters
    class JsonApiOauthClient
      def initialize(partner:)
        @partner = partner
      end

      # Returns a valid access token, refreshing if expired or absent.
      #
      # @return [String, nil] the Bearer access token, or nil on failure
      def access_token
        cached = @partner.metadata&.dig("oauth_access_token")
        expires = @partner.metadata&.dig("oauth_token_expires_at")

        if cached.present? && expires.present? && Time.zone.parse(expires) > Time.current
          return cached
        end

        refresh_token
      end

      private

      def refresh_token
        token_url = @partner.metadata&.dig("oauth_token_url")
        client_id = @partner.metadata&.dig("oauth_client_id")
        client_secret = @partner.api_key_hash # repurpose encrypted field

        return nil unless token_url && client_id && client_secret

        uri = URI(token_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 10

        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/x-www-form-urlencoded"
        request.body = URI.encode_www_form(
          grant_type: "client_credentials",
          client_id: client_id,
          client_secret: client_secret
        )

        response = http.request(request)
        return nil unless response.code.to_i == 200

        data = JSON.parse(response.body) rescue nil
        return nil unless data.is_a?(Hash)

        token = data["access_token"]
        return nil if token.blank?  # Never cache nil/blank tokens

        expires_in = data["expires_in"] || 3600

        # Cache token and expiry in partner metadata
        @partner.update(metadata: (@partner.metadata || {}).merge(
          "oauth_access_token" => token,
          "oauth_token_expires_at" => (Time.current + expires_in.to_i.seconds).iso8601
        ))

        token
      rescue StandardError => e
        Rails.logger.error("[Federation::OAuth2] Token refresh failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end

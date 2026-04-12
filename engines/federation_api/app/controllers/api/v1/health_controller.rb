# Federation API: Health check endpoint.
#
# Used by Nexus's FederationExternalApiClient.healthCheck()
# to verify this TimeOverflow instance is reachable and operational.
#
module Api
  module V1
    class HealthController < BaseController
      # Skip auth for health checks — Nexus needs to ping even if
      # credentials are misconfigured
      skip_before_action :authenticate_api_key!
      skip_before_action :enforce_rate_limit!

      # GET /api/v1/health
      def show
        db_ok = begin
          ActiveRecord::Base.connection.select_value("SELECT 1").to_i == 1
        rescue => e
          Rails.logger.error("[Federation Health] DB check failed: #{e.class}: #{e.message}")
          false
        end

        # H4: Check Redis/cache connectivity — Sidekiq and rate limiting depend on it.
        # Use a lightweight write+read cycle rather than a raw Redis ping so we
        # exercise the same Rails.cache path that the API hot paths use.
        cache_ok = begin
          test_key = "federation_health_check:#{SecureRandom.hex(4)}"
          Rails.cache.write(test_key, "1", expires_in: 5.seconds)
          Rails.cache.read(test_key) == "1"
        rescue => e
          Rails.logger.error("[Federation Health] Cache/Redis check failed: #{e.class}: #{e.message}")
          false
        end

        all_ok = db_ok && cache_ok
        status = all_ok ? :ok : :service_unavailable

        health_data = {
          status: all_ok ? "healthy" : "unhealthy",
          platform: "timeoverflow",
          version: FederationApi::VERSION,
          timestamp: Time.current.iso8601,
          checks: {
            database: db_ok ? "ok" : "error",
            cache: cache_ok ? "ok" : "error",
            federation_api: "ok"
          },
          organizations_count: (Organization.count rescue 0),
          federation_partners_count: (FederationPartner.active.count rescue 0)
        }

        respond_with_data(health_data, status: status)
      end
    end
  end
end

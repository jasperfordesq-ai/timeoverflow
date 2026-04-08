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

        status = db_ok ? :ok : :service_unavailable

        render json: {
          success: db_ok,
          data: {
            status: db_ok ? "healthy" : "unhealthy",
            platform: "timeoverflow",
            version: "1.0.0-federation",
            timestamp: Time.current.iso8601,
            checks: {
              database: db_ok ? "ok" : "error",
              federation_api: "ok"
            },
            organizations_count: (Organization.count rescue 0),
            federation_partners_count: (FederationPartner.active.count rescue 0)
          }
        }, status: status
      end
    end
  end
end

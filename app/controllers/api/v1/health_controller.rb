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

      # GET /api/v1/health
      def show
        db_ok = begin
          ActiveRecord::Base.connection.execute("SELECT 1")
          true
        rescue
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
            organizations_count: Organization.count,
            federation_partners_count: FederationPartner.active.count
          }
        }, status: status
      end
    end
  end
end

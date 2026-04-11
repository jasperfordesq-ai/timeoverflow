# Base controller for the Federation API.
#
# All federation API endpoints authenticate via API key passed in the
# X-Federation-Api-Key header. This mirrors Nexus's FederationApiMiddleware
# pattern for external partner authentication.
#
module Api
  module V1
    class BaseController < ActionController::API
      # devise-i18n compatibility handled by FederationApi::Engine initializer.

      before_action :authenticate_api_key!
      before_action :enforce_rate_limit!
      before_action :set_default_format

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
      rescue_from ActionController::ParameterMissing, with: :bad_request

      private

      def authenticate_api_key!
        raw_key = extract_api_key
        @current_api_key = FederationApiKey.authenticate(raw_key)

        unless @current_api_key
          respond_with_error("Invalid or expired API key", status: :unauthorized)
          return
        end

        @current_api_key.touch_last_used!
      end

      # Accept API key from header only. Supports both:
      #   - X-Federation-Api-Key: <key> (TimeOverflow native)
      #   - Authorization: Bearer <key> (Nexus api_key auth method)
      # Query parameter auth removed for security (keys leak in logs/URLs).
      def extract_api_key
        key = request.headers["X-Federation-Api-Key"]
        return key if key.present?

        auth_header = request.headers["Authorization"]
        if auth_header.present? && auth_header.start_with?("Bearer ")
          return auth_header.delete_prefix("Bearer ")
        end

        nil
      end

      def require_permission!(permission)
        unless @current_api_key.has_permission?(permission)
          respond_with_error("API key lacks '#{permission}' permission", status: :forbidden)
        end
      end

      # Resolve organization. If the API key is scoped to an org, enforce it.
      # If the key is global (no org), allow params[:organization_id] as a filter.
      def current_organization
        @current_organization ||= if @current_api_key.organization
          # Key is org-specific — ignore params, enforce the key's org
          @current_api_key.organization
        else
          # Global key — allow org selection via param
          Organization.find_by(id: params[:organization_id])
        end
      end

      def require_organization!
        unless current_organization
          respond_with_error("organization_id is required", status: :bad_request)
          return
        end
        # Enforce org-level federation setting: if the org has explicitly
        # disabled federation, reject the request.
        unless Federation::AccessControl.org_enabled?(current_organization)
          respond_with_error("Federation is not enabled for this organization", status: :forbidden)
        end
      end

      # Simple sliding-window rate limiter using Rails cache.
      # Limits each API key to N requests per minute.
      def enforce_rate_limit!
        return unless @current_api_key # skip if auth failed (will 401 anyway)

        limit = [Rails.application.config.federation.rate_limit, 1].max rescue 100
        cache_key = "federation_rate:#{@current_api_key.id}:#{Time.current.to_i / 60}"

        count = Rails.cache.increment(cache_key, 1, expires_in: 2.minutes) || 1

        response.set_header("X-RateLimit-Limit", limit.to_s)
        response.set_header("X-RateLimit-Remaining", [limit - count, 0].max.to_s)

        # Rate limit: count > limit allows exactly `limit` requests per window.
        # (count starts at 1 after first increment; the (limit+1)-th request is rejected.)
        if count > limit
          render json: {
            success: false,
            error: "Rate limit exceeded",
            message: "Maximum #{limit} requests per minute"
          }, status: :too_many_requests
        end
      end

      def set_default_format
        request.format = :json
      end

      # Standard JSON envelope matching Nexus's v2 response format.
      # meta is always included (even if empty) for consistent destructuring.
      def respond_with_data(data, status: :ok, meta: {})
        render json: { success: true, data: data, meta: meta }, status: status
      end

      def respond_with_error(message, status: :unprocessable_entity, errors: nil)
        body = { success: false, error: message }
        body[:errors] = errors if errors.present?
        render json: body, status: status
      end

      def not_found(_exception)
        render json: { success: false, error: "Not found" }, status: :not_found
      end

      def unprocessable_entity(exception)
        render json: {
          success: false,
          error: "Validation failed",
          errors: exception.record.errors.full_messages
        }, status: :unprocessable_entity
      end

      def bad_request(_exception)
        render json: { success: false, error: "Bad request" }, status: :bad_request
      end

      # Pagination helper
      def paginate(scope)
        page = [(params[:page] || 1).to_i, 1].max
        per_page = [[(params[:per_page] || 25).to_i, 1].max, 100].min
        paginated = scope.page(page).per(per_page)

        meta = {
          current_page: paginated.current_page,
          total_pages: paginated.total_pages,
          total_count: paginated.total_count,
          per_page: per_page
        }

        [paginated, meta]
      end
    end
  end
end

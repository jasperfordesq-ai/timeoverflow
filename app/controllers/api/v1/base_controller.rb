# Base controller for the Federation API.
#
# All federation API endpoints authenticate via API key passed in the
# X-Federation-Api-Key header. This mirrors Nexus's FederationApiMiddleware
# pattern for external partner authentication.
#
module Api
  module V1
    class BaseController < ActionController::API
      before_action :authenticate_api_key!
      before_action :set_default_format

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
      rescue_from ActionController::ParameterMissing, with: :bad_request

      private

      def authenticate_api_key!
        raw_key = request.headers["X-Federation-Api-Key"]
        @current_api_key = FederationApiKey.authenticate(raw_key)

        unless @current_api_key
          render json: { error: "Unauthorized", message: "Invalid or expired API key" }, status: :unauthorized
          return
        end

        @current_api_key.touch_last_used!
      end

      def require_permission!(permission)
        unless @current_api_key.has_permission?(permission)
          render json: { error: "Forbidden", message: "API key lacks '#{permission}' permission" }, status: :forbidden
        end
      end

      # Resolve organization from the API key or from a query parameter
      def current_organization
        @current_organization ||= @current_api_key.organization || Organization.find_by(id: params[:organization_id])
      end

      def require_organization!
        unless current_organization
          render json: { error: "Bad Request", message: "organization_id is required" }, status: :bad_request
        end
      end

      def set_default_format
        request.format = :json
      end

      # Standard JSON envelope matching Nexus's v2 response format
      def respond_with_data(data, status: :ok, meta: {})
        body = { success: true, data: data }
        body[:meta] = meta if meta.present?
        render json: body, status: status
      end

      def respond_with_error(message, status: :unprocessable_entity, errors: nil)
        body = { success: false, error: message }
        body[:errors] = errors if errors.present?
        render json: body, status: status
      end

      def not_found(exception)
        render json: { success: false, error: "Not found", message: exception.message }, status: :not_found
      end

      def unprocessable_entity(exception)
        render json: {
          success: false,
          error: "Validation failed",
          errors: exception.record.errors.full_messages
        }, status: :unprocessable_entity
      end

      def bad_request(exception)
        render json: { success: false, error: "Bad request", message: exception.message }, status: :bad_request
      end

      # Pagination helper
      def paginate(scope)
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 25).to_i, 100].min
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

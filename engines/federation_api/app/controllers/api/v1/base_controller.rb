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

      before_action :reject_oversized_params!
      before_action :authenticate_api_key!
      before_action :enforce_rate_limit!
      before_action :set_default_format

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable_entity
      rescue_from ActionController::ParameterMissing, with: :bad_request
      rescue_from JSON::ParserError, with: :bad_json
      rescue_from StandardError, with: :handle_unexpected_error

      private

      def authenticate_api_key!
        raw_key = extract_api_key
        @current_api_key = FederationApiKey.authenticate(raw_key)

        unless @current_api_key
          respond_with_error(I18n.t("federation_api.errors.invalid_api_key", default: "Invalid or expired API key"), status: :unauthorized)
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
          respond_with_error(I18n.t("federation_api.errors.missing_permission", permission: permission, default: "API key lacks '%{permission}' permission"), status: :forbidden)
          return
        end
      end

      # Resolve organization. If the API key is scoped to an org, enforce it.
      # If the key is global, allow params[:organization_id] but check
      # permitted_organization_ids for fine-grained access control.
      def current_organization
        @current_organization ||= if @current_api_key&.organization
          # Key is org-specific — ignore params, enforce the key's org
          @current_api_key.organization
        else
          # Global key or no key (public endpoints) — allow org selection via param
          org = Organization.find_by(id: params[:organization_id])
          # Enforce org allowlist if the key has one configured
          if org && @current_api_key && !@current_api_key.can_access_organization?(org)
            nil # blocked — will trigger require_organization! error
          else
            org
          end
        end
      end

      def require_organization!
        unless current_organization
          respond_with_error(I18n.t("federation_api.errors.org_required", default: "organization_id is required"), status: :bad_request)
          return
        end
        # Enforce org-level federation setting: if the org has explicitly
        # disabled federation, reject the request.
        unless Federation::AccessControl.org_enabled?(current_organization)
          respond_with_error(I18n.t("federation_api.errors.federation_disabled", default: "Federation is not enabled for this organization"), status: :forbidden)
          return
        end
      end

      # Sliding-window rate limiter using Rails cache.
      # Uses two adjacent 1-minute buckets weighted by position within the
      # current minute, preventing the 2x burst exploit at window boundaries.
      # Limits each API key to N requests per minute.
      def enforce_rate_limit!
        return unless @current_api_key # skip if auth failed (will 401 anyway)

        limit = begin
          [Rails.application.config.federation.rate_limit, 1].max
        rescue NoMethodError, ArgumentError => e
          Rails.logger.warn("[Federation::API] Rate limit config unavailable (#{e.class}), using default 100")
          100
        end
        now = Time.current.to_i
        current_window = now / 60
        previous_window = current_window - 1
        elapsed_fraction = (now % 60) / 60.0

        current_key  = "federation_rate:#{@current_api_key.id}:#{current_window}"
        previous_key = "federation_rate:#{@current_api_key.id}:#{previous_window}"

        # Increment current window count
        current_count = Rails.cache.increment(current_key, 1, expires_in: 2.minutes) || 1
        previous_count = Rails.cache.read(previous_key).to_i

        # Weighted estimate: previous window's remainder + current window's count
        estimated = (previous_count * (1 - elapsed_fraction)) + current_count

        # Expose rate limit headers (auth is already guaranteed by the early return above).
        response.set_header("X-RateLimit-Limit", limit.to_s)
        response.set_header("X-RateLimit-Remaining", [limit - estimated.ceil, 0].max.to_s)

        if estimated > limit
          response.set_header("Retry-After", "60")
          respond_with_error(I18n.t("federation_api.errors.rate_limited", limit: limit, default: "Rate limit exceeded — maximum %{limit} requests per minute"), status: :too_many_requests)
          return
        end
      end

      # Reject requests with excessively large parameter payloads (>10KB total).
      # Prevents abuse via oversized query strings or JSON bodies that could
      # consume excessive memory during parameter parsing.
      def reject_oversized_params!
        total_size = request.query_string.to_s.bytesize + request.raw_post.to_s.bytesize
        if total_size > 10_240
          respond_with_error(I18n.t("federation_api.errors.params_too_large", default: "Request parameters too large"), status: :bad_request)
          return
        end
      end

      # Validate Content-Type for POST/PUT/PATCH requests on API endpoints.
      # Ensures clients send JSON, preventing accidental form submissions or
      # content-type confusion attacks.
      def require_json_content_type!
        return unless %w[POST PUT PATCH].include?(request.method)

        content_type = request.content_type.to_s.downcase
        unless content_type.include?("application/json") || content_type.include?("application/vnd.api+json")
          respond_with_error(I18n.t("federation_api.errors.invalid_content_type", default: "Content-Type must be application/json"), status: :unsupported_media_type)
          return
        end
      end

      def set_default_format
        request.format = :json
      end

      # Content-negotiation: select the appropriate response adapter based
      # on the Accept header. JSON:API clients (Komunitin) send
      # "application/vnd.api+json"; all others get the standard REST envelope.
      def current_response_adapter
        @current_response_adapter ||= if request.headers["Accept"]&.match?(/\Aapplication\/vnd\.api\+json(\z|[;\s,])/)
          Federation::Adapters::JsonApiAdapter.new(partner: nil)
        else
          Federation::Adapters::RestAdapter.new(partner: nil)
        end
      end

      # Standard JSON envelope matching Nexus's v2 response format, with
      # automatic content negotiation for JSON:API clients.
      # meta is always included (even if empty) for consistent destructuring.
      def respond_with_data(data, status: :ok, meta: {}, resource_type: nil)
        meta = meta.merge(request_id: request.request_id) if request.respond_to?(:request_id)
        body = current_response_adapter.serialize_response(data, meta: meta, resource_type: resource_type)
        response.set_header("X-Request-Id", request.request_id) if request.respond_to?(:request_id)
        response.set_header("X-API-Version", "1.0")
        render json: body, status: status, content_type: current_response_adapter.content_type
      end

      def respond_with_error(message, status: :unprocessable_entity, errors: nil)
        status_code = Rack::Utils::SYMBOL_TO_STATUS_CODE[status] || status
        error_meta = { status_code: status_code, timestamp: Time.current.iso8601 }
        error_meta[:request_id] = request.request_id if request.respond_to?(:request_id)
        body = current_response_adapter.serialize_error(message, status: status_code, errors: errors, meta: error_meta)
        response.set_header("X-Request-Id", request.request_id) if request.respond_to?(:request_id)
        response.set_header("X-API-Version", "1.0")
        render json: body, status: status, content_type: current_response_adapter.content_type
      end

      def not_found(_exception)
        respond_with_error(I18n.t("federation_api.errors.not_found", default: "Not found"), status: :not_found)
      end

      def unprocessable_entity(exception)
        # Return field-level error codes without exposing schema details.
        # Defensive nil check: RecordInvalid can sometimes have a nil record
        # (e.g., when raised manually without an associated model instance).
        sanitized = if exception.record&.errors
          exception.record.errors.map do |error|
            { field: error.attribute.to_s, code: error.type.to_s }
          end
        else
          [{ code: "invalid" }]
        end
        respond_with_error(I18n.t("federation_api.errors.validation_failed", default: "Validation failed"), status: :unprocessable_entity, errors: sanitized)
      end

      def bad_request(_exception)
        respond_with_error(I18n.t("federation_api.errors.bad_request", default: "Bad request"), status: :bad_request)
      end

      def bad_json(_exception)
        respond_with_error(I18n.t("federation_api.errors.invalid_json", default: "Invalid JSON in request body"), status: :bad_request)
      end

      def handle_unexpected_error(exception)
        Rails.logger.error("[Federation::API] Unexpected error: #{exception.class}: #{exception.message}\n#{exception.backtrace&.first(10)&.join("\n")}")
        respond_with_error(I18n.t("federation_api.errors.internal_server_error", default: "Internal server error"), status: :internal_server_error)
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
          per_page: per_page,
          max_per_page: 100
        }

        [paginated, meta]
      end
    end
  end
end

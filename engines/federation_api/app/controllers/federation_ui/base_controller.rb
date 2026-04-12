# Base controller for federation UI API endpoints.
#
# These are JSON endpoints intended for the TimeOverflow frontend (not for
# external partners). They use Devise session authentication (the logged-in
# user), not API key auth.
#
# Mounted at /federation/* by the engine's route initializer.
#
module FederationUi
  class BaseController < ActionController::Base
    protect_from_forgery with: :exception
    before_action :authenticate_user!

    private

    # Resolve the logged-in user from Devise's Warden session.
    def current_user
      @current_user ||= request.env["warden"]&.user(:user)
    end

    def authenticate_user!
      unless current_user
        render json: { success: false, error: "Not authenticated" }, status: :unauthorized
      end
    end

    # Resolve the user's current organization from the session (matches TO's pattern).
    def current_organization
      @current_organization ||= begin
        org_id = session[:current_organization_id]
        if org_id
          Organization.find_by(id: org_id)
        else
          current_user&.organizations&.first
        end
      end
    end

    # Resolve the current user's membership in the current org.
    def current_member
      @current_member ||= begin
        return nil unless current_user && current_organization
        Member.find_by(user: current_user, organization: current_organization, active: true)
      end
    end

    def require_manager!
      unless current_member&.manager?
        render json: { success: false, error: "Manager access required" }, status: :forbidden
      end
    end

    def require_active_member!
      unless current_member
        render json: { success: false, error: "Active membership in current organization required" }, status: :forbidden
      end
    end

    def respond_with_data(data, status: :ok, meta: {})
      render json: { success: true, data: data, meta: meta }, status: status
    end

    def respond_with_error(message, status: :unprocessable_entity, meta: {})
      render json: { success: false, error: message, meta: meta }, status: status
    end
  end
end

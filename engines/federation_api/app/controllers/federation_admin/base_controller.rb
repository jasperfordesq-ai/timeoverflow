# Base controller for the Federation Admin panel.
#
# Inherits from ActionController::Base (not API) to get full view rendering,
# session handling, and CSRF protection. Authentication piggybacks on the
# host app's Devise session — no Devise configuration changes needed.
#
# Mounted at /federation-admin by the engine's route initializer.
#
module FederationAdmin
  class BaseController < ActionController::Base
    before_action :set_locale
    before_action :authenticate_federation_admin!
    layout "federation_admin"

    rescue_from ActiveRecord::RecordNotFound do
      flash[:alert] = "The requested resource could not be found."
      redirect_to federation_admin_root_path
    end

    rescue_from StandardError do |e|
      raise e if Rails.env.development? || Rails.env.test?
      Rails.logger.error("[FederationAdmin] Unhandled error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      flash[:alert] = "An unexpected error occurred. Please try again."
      redirect_to federation_admin_root_path
    end
    helper FederationAdmin::ApplicationHelper

    helper_method :current_user, :federation_stats

    private

    # Reuse Devise's session. The host app defines `current_user` via Devise;
    # since this is a non-isolated engine, it's available here automatically.
    def set_locale
      I18n.locale =
        params[:locale] ||
        current_user&.locale ||
        session[:locale] ||
        I18n.default_locale
    end

    def authenticate_federation_admin!
      unless current_user&.superadmin?
        if current_user
          render plain: "403 — Federation admin requires superadmin privileges.", status: :forbidden
        else
          redirect_to "/login"
        end
      end
    end

    # Devise helper — available because the host app loads Devise.
    def current_user
      @current_user ||= begin
        warden = request.env["warden"]
        warden&.user(:user)
      end
    end

    # Audit logging helper — call from any admin controller action.
    def audit!(action, target: nil, changes_made: {})
      FederationAuditLog.record!(
        action: action,
        actor: current_user,
        target: target,
        changes_made: changes_made,
        ip_address: request.remote_ip
      )
    rescue => e
      Rails.logger.error("[FederationAdmin] Audit log failed: #{e.message}")
    end

    # Quick stats for the sidebar/header
    def federation_stats
      @federation_stats ||= {
        partners_active: FederationPartner.active.count,
        partners_total: FederationPartner.count,
        transactions_total: FederationTransaction.count,
        transactions_pending: FederationTransaction.pending.count,
        api_keys_active: FederationApiKey.active.count,
        webhook_logs_failed: FederationWebhookLog.failed.count,
        messages_total: (FederationMessage.count rescue 0),
        messages_pending: (FederationMessage.pending.count rescue 0),
        orgs_federation_enabled: (FederationOrganizationSetting.where(federation_enabled: true).count rescue 0),
        members_opted_in: (FederationMemberPreference.opted_in.count rescue 0)
      }
    end
  end
end

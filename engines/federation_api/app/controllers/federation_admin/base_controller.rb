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
    before_action :authenticate_federation_admin!
    layout "federation_admin"

    helper_method :current_user, :federation_stats

    private

    # Reuse Devise's session. The host app defines `current_user` via Devise;
    # since this is a non-isolated engine, it's available here automatically.
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

    # Quick stats for the sidebar/header
    def federation_stats
      @federation_stats ||= {
        partners_active: FederationPartner.active.count,
        partners_total: FederationPartner.count,
        transactions_total: FederationTransaction.count,
        transactions_pending: FederationTransaction.pending.count,
        api_keys_active: FederationApiKey.active.count,
        webhook_logs_failed: FederationWebhookLog.failed.count
      }
    end
  end
end

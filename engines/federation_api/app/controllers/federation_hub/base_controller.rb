# Base controller for the Federation Hub — member-facing HTML pages.
#
# Uses the HOST APP's layout ("application") so pages look identical
# to native TimeOverflow pages. Bootstrap 5, Work Sans font, and all
# host helpers (glyph, t, current_user) are automatically available.
#
# Authentication: Devise session (same as the rest of TimeOverflow).
# Authorization: requires an active member in the current organization.
#
# Mounted at /federation-hub by the engine's route initializer.
#
module FederationHub
  class BaseController < ActionController::Base
    protect_from_forgery with: :exception
    before_action :set_locale
    before_action :authenticate_member!
    layout "federation_hub"

    rescue_from ActiveRecord::RecordNotFound do
      flash[:alert] = t("federation_hub.errors.not_found", default: "The requested resource could not be found.")
      redirect_to federation_hub_root_path
    end

    rescue_from StandardError do |e|
      raise e if Rails.env.development? || Rails.env.test?
      Rails.logger.error("[FederationHub] Unhandled error: #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      flash[:alert] = t("federation_hub.errors.unexpected", default: "An unexpected error occurred. Please try again.")
      redirect_to federation_hub_root_path
    end
    helper FederationHub::ApplicationHelper

    helper_method :current_user, :current_organization, :current_member,
                  :federation_preferences, :federation_org_settings, :unread_message_count

    private

    def current_user
      @current_user ||= begin
        warden = request.env["warden"]
        warden&.user(:user)
      end
    end

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

    def current_member
      @current_member ||= begin
        return nil unless current_user && current_organization
        current_organization.members.find_by(user: current_user, active: true)
      end
    end

    def federation_preferences
      @federation_preferences ||= current_member ? FederationMemberPreference.for(current_member) : nil
    end

    def federation_org_settings
      @federation_org_settings ||= current_organization ? FederationOrganizationSetting.for(current_organization) : nil
    end

    def unread_message_count
      @unread_message_count ||= begin
        return 0 unless current_member && current_organization
        FederationMessage.where(
          organization_id: current_organization.id,
          local_member_id: current_member.id,
          direction: "inbound"
        ).where(read_at: nil).count
      rescue
        0
      end
    end

    def set_locale
      I18n.locale =
        params[:locale] ||
        current_user&.locale ||
        session[:locale] ||
        I18n.default_locale
    end

    def authenticate_member!
      unless current_user
        redirect_to "/login"
        return
      end
      unless current_member
        redirect_to "/", alert: t("federation_hub.errors.no_active_membership",
                                   default: "You need an active membership to access the Federation Hub.")
      end
    end
  end
end

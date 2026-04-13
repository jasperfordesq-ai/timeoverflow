module FederationHub
  class SettingsController < BaseController
    def show
      @prefs = federation_preferences
      @org_settings = federation_org_settings
      @effective_status = Federation::AccessControl.effective_status(current_member)
      @partners = FederationPartner.active.order(name: :asc)
    end

    def update
      prefs = federation_preferences
      was_opted_in = prefs.opted_in?

      attrs = {}
      %w[discoverable share_profile share_listings allow_inbound_transfers allow_outbound_transfers].each do |key|
        attrs[key] = params[key] == "1" if params.key?(key)
      end

      if params.key?(:blocked_partner_ids)
        attrs[:blocked_partner_ids] = Array(params[:blocked_partner_ids]).reject(&:blank?).map(&:to_i)
      end

      if params.key?(:opted_in)
        new_opted_in = params[:opted_in] == "1"
        if new_opted_in && !was_opted_in
          attrs[:opted_in] = true
          attrs[:opted_in_at] = Time.current
          attrs[:opted_out_at] = nil
        elsif !new_opted_in && was_opted_in
          attrs[:opted_in] = false
          attrs[:opted_out_at] = Time.current
        end
      end

      prefs.update!(attrs)
      redirect_to federation_hub_settings_path, notice: t("federation_hub.settings.updated")
    rescue => e
      Rails.logger.error("[FederationHub::Settings] Update failed: #{e.class}: #{e.message}")
      redirect_to federation_hub_settings_path,
        alert: t("federation_hub.settings.update_failed_generic", default: "Settings could not be saved. Please try again.")
    end
  end
end

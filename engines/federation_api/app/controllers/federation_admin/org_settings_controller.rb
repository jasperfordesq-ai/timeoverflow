module FederationAdmin
  class OrgSettingsController < BaseController
    def index
      @organizations = Organization.order(:name)
      @settings_map = {}
      FederationOrganizationSetting.all.each do |s|
        @settings_map[s.organization_id] = s
      end
      @opted_in_counts = FederationMemberPreference.opted_in
        .group(:organization_id).count
      @total_member_counts = Member.where(active: true)
        .group(:organization_id).count
    end

    def edit
      @org = Organization.find(params[:id])
      @settings = FederationOrganizationSetting.for(@org)
      @partners = FederationPartner.active.order(:name)
    end

    def update
      @org = Organization.find(params[:id])
      @settings = FederationOrganizationSetting.for(@org)

      permitted = %w[
        federation_enabled discoverable_by_partners
        allow_inbound_transfers allow_outbound_transfers
        share_member_count share_listings share_member_profiles
        auto_approve_partnerships
      ]

      attrs = {}
      permitted.each do |key|
        attrs[key] = params[key] == "1" if params.key?(key)
      end

      if params[:blocked_partner_ids].present?
        attrs[:blocked_partner_ids] = params[:blocked_partner_ids].reject(&:blank?).map(&:to_i)
      else
        attrs[:blocked_partner_ids] = []
      end

      @settings.update!(attrs)
      flash[:notice] = "Federation settings for '#{@org.name}' updated."
      redirect_to federation_admin_org_settings_path
    rescue => e
      flash[:alert] = "Failed to update settings: #{e.message}"
      redirect_to edit_federation_admin_org_setting_path(@org)
    end
  end
end

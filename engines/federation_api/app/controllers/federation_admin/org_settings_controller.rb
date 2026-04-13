module FederationAdmin
  class OrgSettingsController < BaseController
    PER_PAGE = 25

    def index
      @organizations = Organization.includes(:account).order(:name)
      @total_count = @organizations.count
      page = [(params[:page] || 1).to_i, 1].max
      @total_pages = @total_count.zero? ? 0 : (@total_count.to_f / PER_PAGE).ceil
      @current_page = [page, [@total_pages, 1].max].min
      @organizations = @organizations.offset((@current_page - 1) * PER_PAGE).limit(PER_PAGE)

      visible_org_ids = @organizations.map(&:id)
      @settings_map = FederationOrganizationSetting.where(organization_id: visible_org_ids).index_by(&:organization_id)
      @opted_in_counts = FederationMemberPreference.opted_in
        .where(organization_id: visible_org_ids).group(:organization_id).count
      @total_member_counts = Member.where(active: true)
        .where(organization_id: visible_org_ids).group(:organization_id).count
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
        auto_approve_partnerships enable_internal_federation
      ]

      attrs = {}
      permitted.each do |key|
        attrs[key] = params[key] == "1" if params.key?(key)
      end

      if params.key?(:blocked_partners_rendered)
        if params[:blocked_partner_ids].present?
          attrs[:blocked_partner_ids] = params[:blocked_partner_ids].reject(&:blank?).map(&:to_i)
        else
          attrs[:blocked_partner_ids] = []
        end
      end

      @settings.update!(attrs)
      audit!("org_settings.updated", target: @settings, changes_made: @settings.previous_changes.except("updated_at"))
      flash[:notice] = t("federation_admin.flash.org_settings_updated", name: @org.name, default: "Federation settings for '%{name}' updated.")
      redirect_to federation_admin_org_settings_path
    rescue => e
      flash[:alert] = t("federation_admin.flash.org_settings_failed", error: e.message, default: "Failed to update settings: %{error}")
      redirect_to edit_federation_admin_org_setting_path(@org)
    end
  end
end

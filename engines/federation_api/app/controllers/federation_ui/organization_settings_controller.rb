# GET/PATCH /federation/org-settings
#
# Organization-level federation settings. Only accessible to org managers.
# Allows managers to enable/disable federation for their time bank.
#
module FederationUi
  class OrganizationSettingsController < BaseController
    before_action :require_active_member!
    before_action :require_manager!

    # GET /federation/org-settings
    def show
      org = current_organization
      settings = FederationOrganizationSetting.for(org)
      partners = FederationPartner.active.for_organization(org.id)

      opted_in_count = FederationMemberPreference
        .where(organization_id: org.id, opted_in: true).count
      total_active = org.members.active.count

      respond_with_data({
        organization_id: org.id,
        organization_name: org.name,
        federation_enabled: settings.federation_enabled?,
        discoverable_by_partners: settings.discoverable?,
        allow_inbound_transfers: settings.allows_inbound?,
        allow_outbound_transfers: settings.allows_outbound?,
        share_member_count: settings.share_member_count,
        share_listings: settings.share_listings,
        share_member_profiles: settings.share_member_profiles,
        auto_approve_partnerships: settings.auto_approve_partnerships,
        blocked_partner_ids: settings.blocked_partner_ids,
        active_partners: partners.map { |p|
          { id: p.id, name: p.name, status: p.status, partnership_level: p.partnership_level }
        },
        opted_in_members_count: opted_in_count,
        total_active_members_count: total_active
      })
    end

    # PATCH /federation/org-settings
    def update
      settings = FederationOrganizationSetting.for(current_organization)

      permitted = %w[
        federation_enabled discoverable_by_partners
        allow_inbound_transfers allow_outbound_transfers
        share_member_count share_listings share_member_profiles
        auto_approve_partnerships
      ]

      attrs = {}
      permitted.each do |key|
        attrs[key] = ActiveModel::Type::Boolean.new.cast(params[key]) if params.key?(key)
      end

      if params.key?(:blocked_partner_ids)
        attrs[:blocked_partner_ids] = Array(params[:blocked_partner_ids]).map(&:to_i)
      end

      settings.update!(attrs)

      respond_with_data({ updated: true, federation_enabled: settings.federation_enabled? })
    rescue ActiveRecord::RecordInvalid => e
      respond_with_error(e.record.errors.full_messages.join(", "))
    end
  end
end

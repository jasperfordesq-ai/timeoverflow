# GET /federation/status
#
# Returns federation availability and status for the current user.
# The host UI calls this to decide whether to show federation UI elements.
#
module FederationUi
  class StatusController < BaseController
    def show
      org = current_organization
      member = current_member

      org_settings = org ? FederationOrganizationSetting.for(org) : nil
      member_prefs = member ? FederationMemberPreference.for(member) : nil
      # Single query: fetch names (up to 11 to detect "more"), derive count.
      partner_names = FederationPartner.active.order(:name).limit(11).pluck(:name)
      partner_count = partner_names.length > 10 ? FederationPartner.active.count : partner_names.length

      respond_with_data({
        federation_available: true,
        engine_version: FederationApi::VERSION,
        organization: org ? {
          id: org.id,
          name: org.name,
          federation_enabled: org_settings&.federation_enabled? || false
        } : nil,
        member: member ? {
          id: member.id,
          opted_in: member_prefs&.opted_in? || false,
          discoverable: member_prefs&.discoverable? || false
        } : nil,
        effective_status: member ? Federation::AccessControl.effective_status(member) : nil,
        active_partners_count: partner_count,
        partner_names: partner_names.first(10)
      })
    end
  end
end

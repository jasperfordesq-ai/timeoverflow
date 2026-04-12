# Central access-control service for federation visibility and permissions.
#
# This is the SINGLE SOURCE OF TRUTH for all federation permission checks.
# Both the external API (partner-facing) and the internal UI API (member-facing)
# use this service to determine what's visible and what's allowed.
#
# Consent model (two layers):
#   1. Organization must have federation_enabled = true
#   2. Member must have opted_in = true
#   Both must be true for any federation action involving that member.
#
module Federation
  class AccessControl
    # --- Organization-level checks ---

    def self.org_enabled?(organization)
      FederationOrganizationSetting.for(organization).federation_enabled?
    end

    def self.org_discoverable?(organization)
      settings = FederationOrganizationSetting.for(organization)
      settings.federation_enabled? && settings.discoverable?
    end

    # --- Member-level checks ---

    def self.member_opted_in?(member)
      return false unless org_enabled?(member.organization)
      FederationMemberPreference.for(member).opted_in?
    end

    def self.member_discoverable?(member, settings: nil, prefs: nil)
      settings ||= FederationOrganizationSetting.for(member.organization)
      return false unless settings.federation_enabled?
      return false unless settings.share_member_profiles?
      prefs ||= FederationMemberPreference.for(member)
      prefs.opted_in? && prefs.discoverable?
    end

    def self.member_can_receive?(member, partner: nil, settings: nil, prefs: nil)
      settings ||= FederationOrganizationSetting.for(member.organization)
      return false unless settings.federation_enabled?
      return false unless settings.allows_inbound?
      return false if partner && settings.blocks_partner?(partner.id)
      prefs ||= FederationMemberPreference.for(member)
      return false unless prefs.opted_in? && prefs.allow_inbound_transfers
      return false if partner && prefs.blocks_partner?(partner.id)
      true
    end

    def self.member_can_send?(member, partner: nil, settings: nil, prefs: nil)
      settings ||= FederationOrganizationSetting.for(member.organization)
      return false unless settings.federation_enabled?
      return false unless settings.allows_outbound?
      return false if partner && settings.blocks_partner?(partner.id)
      prefs ||= FederationMemberPreference.for(member)
      return false unless prefs.opted_in? && prefs.allow_outbound_transfers
      return false if partner && prefs.blocks_partner?(partner.id)
      true
    end

    def self.member_listings_visible?(member, settings: nil, prefs: nil)
      settings ||= FederationOrganizationSetting.for(member.organization)
      return false unless settings.federation_enabled?
      return false unless settings.share_listings?
      prefs ||= FederationMemberPreference.for(member)
      prefs.opted_in? && prefs.share_listings
    end

    # Can this member receive cross-platform messages?
    def self.member_can_receive_messages?(member, partner: nil)
      return false unless org_enabled?(member.organization)
      return false if partner && !partner.feature_gates&.dig("messaging_enabled")
      return false if partner && FederationOrganizationSetting.for(member.organization).blocks_partner?(partner.id)
      prefs = FederationMemberPreference.for(member)
      return false unless prefs.opted_in?
      return false if partner && prefs.blocks_partner?(partner.id)
      true
    end

    # --- Bulk queries (for controller filters) ---

    # IDs of members who have opted in for a given organization.
    def self.opted_in_member_ids(organization)
      FederationMemberPreference
        .where(organization_id: organization.id)
        .opted_in
        .pluck(:member_id)
    end

    # IDs of members who are discoverable by federation partners.
    # Requires org-level share_member_profiles to be enabled.
    def self.discoverable_member_ids(organization)
      settings = FederationOrganizationSetting.for(organization)
      return [] unless settings.federation_enabled? && settings.share_member_profiles?

      FederationMemberPreference
        .where(organization_id: organization.id)
        .discoverable
        .pluck(:member_id)
    end

    # --- Effective status (for UI display) ---

    def self.effective_status(member)
      settings = FederationOrganizationSetting.for(member.organization)
      prefs = FederationMemberPreference.for(member)

      {
        org_federation_enabled: settings.federation_enabled?,
        member_opted_in: prefs.opted_in?,
        discoverable_to_partners: member_discoverable?(member, settings: settings, prefs: prefs),
        can_receive_transfers: member_can_receive?(member, settings: settings, prefs: prefs),
        can_send_transfers: member_can_send?(member, settings: settings, prefs: prefs),
        listings_visible: member_listings_visible?(member, settings: settings, prefs: prefs)
      }
    end
  end
end

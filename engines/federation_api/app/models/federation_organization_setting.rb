# Federation settings for a single TimeOverflow organization (time bank).
#
# Controls whether federation is enabled, what data is shared, and which
# partners are blocked. Lazy-initialized via .for(org) — no backfill
# migration needed; records are created with safe defaults on first access.
#
class FederationOrganizationSetting < ActiveRecord::Base
  belongs_to :organization

  validates :organization_id, presence: true, uniqueness: true

  # Find or create settings for an organization (lazy init with safe defaults).
  def self.for(organization)
    org_id = organization.is_a?(Integer) ? organization : organization.id
    find_or_create_by!(organization_id: org_id)
  rescue ActiveRecord::RecordNotUnique
    find_by!(organization_id: org_id)
  end

  def federation_enabled?
    federation_enabled
  end

  def discoverable?
    discoverable_by_partners
  end

  def allows_inbound?
    allow_inbound_transfers
  end

  def allows_outbound?
    allow_outbound_transfers
  end

  def blocks_partner?(partner_id)
    (blocked_partner_ids || []).include?(partner_id)
  end

  def internal_federation_enabled?
    enable_internal_federation
  end
end

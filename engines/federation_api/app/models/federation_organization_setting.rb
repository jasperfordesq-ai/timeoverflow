# Federation settings for a single TimeOverflow organization (time bank).
#
# Controls whether federation is enabled, what data is shared, and which
# partners are blocked. Lazy-initialized via .for(org) — no backfill
# migration needed; records are created with safe defaults on first access.
#
class FederationOrganizationSetting < ActiveRecord::Base
  belongs_to :organization

  validates :organization_id, presence: true, uniqueness: true, numericality: { greater_than: 0 }

  # Find or create settings for an organization (lazy init with safe defaults).
  def self.for(organization)
    org_id = organization.is_a?(Integer) ? organization : organization.id
    find_or_create_by!(organization_id: org_id)
  rescue ActiveRecord::RecordNotUnique
    find_by!(organization_id: org_id)
  end

  # Semantic query aliases for boolean attributes. These provide more expressive
  # method names (e.g. `allows_inbound?` vs `allow_inbound_transfers?`) and
  # exist for readability at call sites. Rails already generates `?` methods
  # for boolean columns, but these aliases use domain-appropriate naming.
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

  before_validation :sanitize_blocked_partner_ids

  def internal_federation_enabled?
    enable_internal_federation
  end

  private

  def sanitize_blocked_partner_ids
    return if blocked_partner_ids.blank?
    # Coerce to integers first — form submissions may store strings (e.g. ["3", "7"])
    # which causes blocks_partner?(3) to return false because "3" != 3.
    self.blocked_partner_ids = blocked_partner_ids.map(&:to_i)
    valid_ids = FederationPartner.where(id: blocked_partner_ids).pluck(:id)
    orphaned = blocked_partner_ids - valid_ids
    if orphaned.any?
      Rails.logger.warn("[FederationOrganizationSetting] Removed #{orphaned.count} orphaned blocked_partner_ids #{orphaned.inspect} from org setting #{id || '(new)'} (org #{organization_id})")
      self.blocked_partner_ids = valid_ids
    end
  end
end

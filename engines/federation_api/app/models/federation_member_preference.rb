# Federation opt-in preferences for a single member (user-in-org).
#
# Consent model: a member is only federated when BOTH:
#   1. Their org has federation_enabled = true (FederationOrganizationSetting)
#   2. They have opted_in = true (this record)
#
# Lazy-initialized via .for(member) — defaults to opted_in: false (safe).
#
class FederationMemberPreference < ActiveRecord::Base
  belongs_to :member

  validates :member_id, presence: true, uniqueness: true
  validates :organization_id, presence: true
  validates :discoverable, inclusion: { in: [true, false] }

  scope :opted_in, -> { where(opted_in: true) }
  scope :discoverable, -> { where(opted_in: true, discoverable: true) }

  # Find or create preferences for a member (lazy init with safe defaults).
  def self.for(member)
    find_or_create_by!(member_id: member.id) do |pref|
      pref.organization_id = member.organization_id
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(member_id: member.id)
  end

  def opted_in?
    return false unless opted_in
    # Timestamp consistency: if opted_out_at is present and more recent than
    # opted_in_at, the boolean flag may be stale. Treat as not opted-in.
    if opted_out_at.present? && opted_in_at.present? && opted_out_at > opted_in_at
      return false
    end
    true
  end

  def discoverable?
    opted_in && discoverable
  end

  def blocks_partner?(partner_id)
    (blocked_partner_ids || []).include?(partner_id)
  end

  validate :sanitize_blocked_partner_ids

  private def sanitize_blocked_partner_ids
    return if blocked_partner_ids.blank?
    valid_ids = FederationPartner.where(id: blocked_partner_ids).pluck(:id)
    orphaned = blocked_partner_ids - valid_ids
    if orphaned.any?
      Rails.logger.warn("[FederationMemberPreference] Stripping orphaned partner IDs #{orphaned} from member pref #{id || '(new)'}")
      self.blocked_partner_ids = valid_ids
    end
  end
  public

  # Opt in with timestamp tracking
  def opt_in!
    return self if opted_in?
    update!(opted_in: true, opted_in_at: Time.current, opted_out_at: nil)
  end

  # Opt out with timestamp tracking
  def opt_out!
    return self unless opted_in?
    update!(opted_in: false, opted_out_at: Time.current)
  end
end

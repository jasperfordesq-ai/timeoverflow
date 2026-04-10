# Represents an external timebanking platform that this TimeOverflow
# instance federates with (e.g., a Nexus tenant).
#
# Partnership levels mirror Nexus's 4-level model:
#   1 = Discovery (can see each other's public metadata)
#   2 = Social (profiles and messaging enabled)
#   3 = Economic (cross-platform time transfers)
#   4 = Integrated (full feature access)
#
class FederationPartner < ActiveRecord::Base
  has_many :federation_transactions, dependent: :restrict_with_error
  has_many :federation_webhook_logs, dependent: :destroy

  STATUSES = %w[pending active suspended terminated].freeze
  PLATFORM_TYPES = %w[nexus timeoverflow custom].freeze
  PARTNERSHIP_LEVELS = (1..4).freeze

  validates :name, presence: true
  validates :platform_type, presence: true, inclusion: { in: PLATFORM_TYPES }
  validates :api_endpoint, presence: true
  validates :webhook_secret, presence: true  # Required: empty secret allows HMAC forgery with key=""
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :partnership_level, inclusion: { in: PARTNERSHIP_LEVELS }
  validates :feature_gates, presence: true   # nil feature_gates crashes can_transact? et al.

  scope :active, -> { where(status: "active") }
  scope :by_platform, ->(type) { where(platform_type: type) }

  # Multi-org scoping: check if this partner can access a given organization.
  # Empty permitted_organization_ids means unrestricted (all orgs).
  def can_access_organization?(org_or_id)
    org_id = org_or_id.is_a?(Integer) ? org_or_id : org_or_id.id
    permitted_organization_ids.blank? || permitted_organization_ids.include?(org_id)
  end

  # Scope: only partners that can access a specific org.
  scope :for_organization, ->(org_id) {
    where("permitted_organization_ids = '[]'::jsonb OR permitted_organization_ids @> ?", [org_id].to_json)
  }

  def active?
    status == "active"
  end

  def can_transact?
    active? && partnership_level >= 3 && feature_gates&.dig("transactions_enabled")
  end

  def can_share_profiles?
    active? && partnership_level >= 2 && feature_gates&.dig("profiles_enabled")
  end

  def can_share_listings?
    active? && partnership_level >= 1 && feature_gates&.dig("listings_enabled")
  end

  def record_failure!
    return if status == "terminated"  # don't touch terminated partners

    # Atomic increment + conditional suspension in one reload cycle
    # to avoid stale in-memory reads under concurrency.
    increment!(:consecutive_failures)
    reload
    update!(status: "suspended") if consecutive_failures >= 5
  end

  def record_success!
    update!(consecutive_failures: 0, last_health_check_at: Time.current)
  end

  def level_name
    { 1 => "Discovery", 2 => "Social", 3 => "Economic", 4 => "Integrated" }[partnership_level]
  end
end

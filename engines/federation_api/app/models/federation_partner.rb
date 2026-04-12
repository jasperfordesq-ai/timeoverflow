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
  has_many :federation_messages, dependent: :restrict_with_error
  has_many :federation_webhook_logs, dependent: :destroy

  STATUSES = %w[pending active suspended terminated].freeze
  PLATFORM_TYPES = %w[nexus timeoverflow custom komunitin].freeze
  PROTOCOL_TYPES = %w[rest json_api credit_commons].freeze
  PARTNERSHIP_LEVELS = (1..4).freeze

  validates :name, presence: true
  validates :platform_type, presence: true, inclusion: { in: PLATFORM_TYPES }
  validates :protocol_type, presence: true, inclusion: { in: PROTOCOL_TYPES }
  validates :api_endpoint, presence: true, format: { with: /\Ahttps?:\/\//i, message: "must be a valid HTTP(S) URL" }
  validates :webhook_secret, presence: true  # Required: empty secret allows HMAC forgery with key=""
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :partnership_level, inclusion: { in: PARTNERSHIP_LEVELS }
  validates :feature_gates, presence: true   # nil feature_gates crashes can_transact? et al.
  validate :valid_status_transition, if: :status_changed?

  # Resolve the protocol adapter for this partner.
  # Mirrors Nexus's resolveAdapter() pattern.
  def adapter
    @adapter ||= Federation::Adapters.resolve(self)
  end

  # Valid status transitions. Terminated partners cannot be reactivated.
  VALID_TRANSITIONS = {
    "pending"    => %w[active suspended terminated],
    "active"     => %w[suspended terminated],
    "suspended"  => %w[active terminated],
    "terminated" => []  # terminal state
  }.freeze

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
    active? && partnership_level >= 3 && feature_gates.dig("transactions_enabled")
  end

  def can_share_profiles?
    active? && partnership_level >= 2 && feature_gates.dig("profiles_enabled")
  end

  def can_share_listings?
    active? && partnership_level >= 1 && feature_gates.dig("listings_enabled")
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

  # Returns all currently valid webhook secrets (supports zero-downtime rotation).
  # During a rotation window both the current and next secret are accepted.
  def valid_webhook_secrets
    [webhook_secret, next_webhook_secret].compact.reject(&:blank?)
  end

  # Start a secret rotation: generate a new secret and store it as next_webhook_secret.
  # Both secrets are accepted until complete_secret_rotation! is called.
  def rotate_webhook_secret!
    new_secret = SecureRandom.hex(32)
    update!(
      next_webhook_secret: new_secret,
      secret_rotation_started_at: Time.current
    )
    new_secret
  end

  # Complete a rotation: promote next_webhook_secret to webhook_secret
  # and clear the rotation fields.
  def complete_secret_rotation!
    raise "No rotation in progress" if next_webhook_secret.blank?
    update!(
      webhook_secret: next_webhook_secret,
      next_webhook_secret: nil,
      secret_rotation_started_at: nil
    )
  end

  def rotation_in_progress?
    next_webhook_secret.present?
  end

  private

  def valid_status_transition
    return if new_record?
    old_status = status_was
    allowed = VALID_TRANSITIONS[old_status] || []
    unless allowed.include?(status)
      errors.add(:status, "cannot transition from '#{old_status}' to '#{status}'")
    end
  end
end

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

  scope :active, -> { where(status: "active") }
  scope :by_platform, ->(type) { where(platform_type: type) }

  def active?
    status == "active"
  end

  def can_transact?
    active? && partnership_level >= 3 && feature_gates["transactions_enabled"]
  end

  def can_share_profiles?
    active? && partnership_level >= 2 && feature_gates["profiles_enabled"]
  end

  def can_share_listings?
    active? && partnership_level >= 1 && feature_gates["listings_enabled"]
  end

  def record_failure!
    increment!(:consecutive_failures)
    update!(status: "suspended") if consecutive_failures >= 5
  end

  def record_success!
    update!(consecutive_failures: 0, last_health_check_at: Time.current)
  end

  def level_name
    { 1 => "Discovery", 2 => "Social", 3 => "Economic", 4 => "Integrated" }[partnership_level]
  end
end

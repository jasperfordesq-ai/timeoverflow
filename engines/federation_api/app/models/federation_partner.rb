require "ipaddr"
require "resolv"
require "timeout"

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
  FAILURE_THRESHOLD = 5

  validates :name, presence: true
  validates :platform_type, presence: true, inclusion: { in: PLATFORM_TYPES }
  validates :protocol_type, presence: true, inclusion: { in: PROTOCOL_TYPES }
  validates :api_endpoint, presence: true, format: { with: /\Ahttps?:\/\//i, message: :invalid_url }
  validates :webhook_secret, presence: true, length: { minimum: 32 }  # Required: empty/short secret allows HMAC forgery
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :partnership_level, inclusion: { in: PARTNERSHIP_LEVELS }
  validates :feature_gates, presence: true   # nil feature_gates crashes can_transact? et al.
  validates :api_key_hash, presence: true
  validate :feature_gates_must_be_hash
  validate :metadata_size_limit
  validate :valid_status_transition, if: :status_changed?
  validate :no_ssrf_urls

  # Resolve the protocol adapter for this partner.
  # Mirrors Nexus's resolveAdapter() pattern.
  def adapter
    Federation::Adapters.resolve(self)
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
    where("permitted_organization_ids IS NULL OR permitted_organization_ids = '[]'::jsonb OR permitted_organization_ids @> ?", [org_id].to_json)
  }

  def active?
    status == "active"
  end

  def can_transact?
    active? && partnership_level >= 3 && feature_gates&.dig("transactions_enabled") == true
  end

  def can_share_profiles?
    active? && partnership_level >= 2 && feature_gates&.dig("profiles_enabled") == true
  end

  def can_share_listings?
    active? && partnership_level >= 1 && feature_gates&.dig("listings_enabled") == true
  end

  def record_failure!
    return if status == "terminated"  # don't touch terminated partners

    # Fully atomic: increment + conditional suspension in a single SQL statement
    # to eliminate race windows under concurrent webhook deliveries.
    self.class.where(id: id).where.not(status: "terminated").update_all([
      "consecutive_failures = consecutive_failures + 1, status = CASE WHEN consecutive_failures + 1 >= ? THEN 'suspended' ELSE status END, updated_at = ?",
      FAILURE_THRESHOLD, Time.current
    ])
    reload
  end

  def record_success!
    update!(consecutive_failures: 0, last_health_check_at: Time.current)
  end

  def level_name
    key = { 1 => "discovery", 2 => "social", 3 => "economic", 4 => "integrated" }[partnership_level]
    key ? I18n.t("federation_admin.common.partnership_levels.#{key}") : nil
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

  # Redact sensitive fields from inspect output to prevent accidental
  # exposure in logs, console output, or error reports.
  def inspect
    super.gsub(/webhook_secret: ".*?"/, 'webhook_secret: "[REDACTED]"')
         .gsub(/next_webhook_secret: ".*?"/, 'next_webhook_secret: "[REDACTED]"')
  end

  # Stale rotation detection: returns true if a secret rotation was started
  # more than 7 days ago and has not been completed. This indicates the
  # partner may have forgotten to call complete_secret_rotation!
  def rotation_stale?
    next_webhook_secret.present? &&
      secret_rotation_started_at.present? &&
      secret_rotation_started_at < 7.days.ago
  end

  validate :sanitize_permitted_organization_ids

  private

  def feature_gates_must_be_hash
    return if feature_gates.blank?  # presence validation handles nil/empty
    unless feature_gates.is_a?(Hash)
      errors.add(:feature_gates, "must be a Hash, got #{feature_gates.class.name}")
    end
  end

  def metadata_size_limit
    return if metadata.blank?
    if metadata.to_json.bytesize > 100_000
      errors.add(:metadata, I18n.t("federation_api.errors.metadata_too_large", max_kb: 100, default: "exceeds %{max_kb} KB size limit"))
    end
  end

  def sanitize_permitted_organization_ids
    return if permitted_organization_ids.blank?
    valid_ids = Organization.where(id: permitted_organization_ids).pluck(:id)
    orphaned = permitted_organization_ids - valid_ids
    if orphaned.any?
      Rails.logger.warn("[FederationPartner] Stripping orphaned org IDs #{orphaned} from partner #{id || '(new)'}")
      self.permitted_organization_ids = valid_ids
    end
  end

  def valid_status_transition
    return if new_record?
    old_status = status_was
    allowed = VALID_TRANSITIONS[old_status] || []
    unless allowed.include?(status)
      errors.add(:status, "cannot transition from '#{old_status}' to '#{status}'")
    end
  end

  # SSRF prevention: reject URLs that point to private/internal IP ranges.
  # Validates api_endpoint, webhook_url, and browse_base_url.
  PRIVATE_IP_RANGES = [
    IPAddr.new("127.0.0.0/8"),      # loopback
    IPAddr.new("10.0.0.0/8"),       # RFC 1918
    IPAddr.new("172.16.0.0/12"),    # RFC 1918
    IPAddr.new("192.168.0.0/16"),   # RFC 1918
    IPAddr.new("169.254.0.0/16"),   # link-local
    IPAddr.new("::1/128"),          # IPv6 loopback
    IPAddr.new("fc00::/7")          # IPv6 unique local
  ].freeze

  def no_ssrf_urls
    %i[api_endpoint webhook_url browse_base_url].each do |attr|
      value = send(attr)
      next if value.blank?
      begin
        host = URI.parse(value).host
        next if host.blank?
        resolved = IPAddr.new(host)
        if PRIVATE_IP_RANGES.any? { |range| range.include?(resolved) }
          errors.add(attr, "must not point to a private/internal IP address")
        end
      rescue IPAddr::InvalidAddressError
        # Host is a hostname, not an IP literal — resolve it.
        # Wrap in a timeout to prevent slow DNS from blocking model saves.
        begin
          addrs = Timeout.timeout(3) { Resolv.getaddresses(host) }
          addrs.each do |addr|
            ip = IPAddr.new(addr)
            if PRIVATE_IP_RANGES.any? { |range| range.include?(ip) }
              errors.add(attr, "must not resolve to a private/internal IP address")
              break
            end
          end
        rescue Resolv::ResolvError, Timeout::Error
          # DNS resolution failed or timed out — allow the URL
          # (real-time SSRF blocking happens at request time)
        end
      rescue URI::InvalidURIError
        errors.add(attr, "is not a valid URL")
      end
    end
  end
end

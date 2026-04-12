# API key for authenticating federation partner requests.
#
# Keys are stored as SHA-256 hashes. The raw key is only shown once
# at creation time. A short prefix is stored for identification.
#
class FederationApiKey < ActiveRecord::Base
  belongs_to :organization, optional: true

  scope :active, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  validates :name, presence: true
  validates :key_hash, presence: true, uniqueness: true
  validates :key_prefix, presence: true

  # Generate a new API key and return the raw key (only available at creation)
  def self.generate!(name:, organization: nil, permissions: {}, expires_at: nil)
    raw_key = "to_fed_#{SecureRandom.hex(32)}"
    key = create!(
      name: name,
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      organization: organization,
      permissions: permissions,
      expires_at: expires_at
    )
    [key, raw_key]
  end

  # Find an active key by its raw value
  def self.authenticate(raw_key)
    return nil if raw_key.blank?
    active.find_by(key_hash: Digest::SHA256.hexdigest(raw_key))
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current)
  end

  def active?
    active && !expired?
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  # Permission keys that the federation API recognises.
  KNOWN_PERMISSIONS = %w[profiles listings transactions].freeze

  # Check whether this key grants a specific permission.
  # Keys with explicit permissions: only the flagged ones are allowed.
  # Keys with *empty* permissions created BEFORE the default-deny change
  # are treated as unrestricted for backward compatibility — but new keys
  # MUST specify at least one permission (see validate_permissions_schema).
  def has_permission?(permission)
    return true if permissions.blank? && persisted? && created_at < Time.utc(2026, 4, 13)
    return false if permissions.blank?
    permissions[permission.to_s] == true
  end

  validate :validate_permissions_schema

  private

  def validate_permissions_schema
    if permissions.blank? && new_record?
      errors.add(:permissions, "must specify at least one permission (profiles, listings, transactions)")
      return
    end
    return if permissions.blank?
    unless permissions.is_a?(Hash)
      errors.add(:permissions, "must be a JSON object")
      return
    end
    unknown = permissions.keys - KNOWN_PERMISSIONS
    errors.add(:permissions, "contains unknown keys: #{unknown.join(', ')}") if unknown.any?
    non_bool = permissions.select { |_, v| ![true, false].include?(v) }
    errors.add(:permissions, "values must be booleans") if non_bool.any?
  end
end

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
  def self.generate!(name:, organization: nil, permissions: {}, expires_at: nil, permitted_organization_ids: nil)
    raw_key = "to_fed_#{SecureRandom.hex(32)}"
    key = new(
      name: name,
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      organization: organization,
      permissions: permissions,
      expires_at: expires_at
    )
    key.permitted_organization_ids = permitted_organization_ids if permitted_organization_ids.present?
    key.save!
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
  # Keys with empty permissions are denied — all keys must specify at
  # least one permission (enforced by validate_permissions_schema).
  def has_permission?(permission)
    return false if permissions.blank?
    permissions[permission.to_s] == true
  end

  # Check if this key is allowed to access a specific organization.
  # Org-scoped keys: only the assigned org.
  # Global keys with permitted_organization_ids: only those orgs.
  # Global keys with empty permitted_organization_ids: all orgs.
  def can_access_organization?(org_or_id)
    org_id = org_or_id.is_a?(Integer) ? org_or_id : org_or_id.id
    if organization_id.present?
      organization_id == org_id
    elsif permitted_organization_ids.present? && permitted_organization_ids.any?
      permitted_organization_ids.include?(org_id)
    else
      true # unrestricted global key
    end
  end

  validate :validate_permissions_schema
  validate :validate_permitted_organization_ids
  validate :validate_expires_at_not_in_past, on: :create

  private

  def validate_permissions_schema
    if permissions.blank?
      errors.add(:permissions, "must specify at least one permission (profiles, listings, transactions)")
      return
    end
    unless permissions.is_a?(Hash)
      errors.add(:permissions, "must be a JSON object")
      return
    end
    unknown = permissions.keys - KNOWN_PERMISSIONS
    errors.add(:permissions, "contains unknown keys: #{unknown.join(', ')}. Valid keys are: #{KNOWN_PERMISSIONS.join(', ')}") if unknown.any?
    non_bool = permissions.select { |_, v| ![true, false].include?(v) }
    errors.add(:permissions, "values must be booleans") if non_bool.any?
  end

  def validate_permitted_organization_ids
    return if permitted_organization_ids.blank?
    return unless permitted_organization_ids.is_a?(Array)
    invalid = permitted_organization_ids.reject { |id| id.is_a?(Integer) && id > 0 }
    errors.add(:permitted_organization_ids, "must contain only positive integers") if invalid.any?
  end

  def validate_expires_at_not_in_past
    return if expires_at.blank?
    if expires_at < Time.current
      errors.add(:expires_at, "cannot be in the past")
    end
  end
end

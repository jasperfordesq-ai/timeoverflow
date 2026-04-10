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

  def has_permission?(permission)
    permissions.blank? || permissions[permission.to_s] == true
  end
end

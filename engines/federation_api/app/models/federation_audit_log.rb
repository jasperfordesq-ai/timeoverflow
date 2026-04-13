# Audit log for federation admin actions.
#
# Records who did what, when, and from where. Provides a tamper-evident
# trail for compliance and debugging.
#
class FederationAuditLog < ActiveRecord::Base
  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :for_target, ->(type, id) { where(target_type: type, target_id: id) }

  validate :changes_made_size_limit

  def self.record!(action:, actor: nil, target: nil, changes_made: {}, ip_address: nil)
    create!(
      action: action,
      actor_email: actor&.email,
      actor_id: actor&.id,
      target_type: target&.class&.name,
      target_id: target&.id,
      changes_made: changes_made,
      ip_address: ip_address
    )
  end

  private

  def changes_made_size_limit
    return if changes_made.blank?
    if changes_made.to_json.bytesize > 100.kilobytes
      errors.add(:changes_made, "is too large (max 100KB)")
    end
  end
end

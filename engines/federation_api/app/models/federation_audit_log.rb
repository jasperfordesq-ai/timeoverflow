# Audit log for federation admin actions.
#
# Records who did what, when, and from where. Provides a tamper-evident
# trail for compliance and debugging.
#
class FederationAuditLog < ActiveRecord::Base
  validates :action, presence: true
  validate :must_have_actor_or_system_action

  scope :recent, -> { order(created_at: :desc) }
  scope :for_target, ->(type, id) { where(target_type: type, target_id: id) }

  validate :changes_made_size_limit

  def self.record!(action:, actor: nil, target: nil, changes_made: {}, ip_address: nil, actor_email: nil)
    create!(
      action: action,
      actor_email: actor_email || actor&.email || "system",
      actor_id: actor&.id,
      target_type: target&.class&.name,
      target_id: target&.id,
      changes_made: changes_made,
      ip_address: ip_address
    )
  end

  private

  # Every audit log should have an identifiable actor (human or system).
  # System-initiated actions (reconciliation, cron) use actor_email "system".
  def must_have_actor_or_system_action
    return if actor_id.present? || actor_email.present?
    errors.add(:base, "must have an actor_id or actor_email")
  end

  def changes_made_size_limit
    return if changes_made.blank?
    if changes_made.to_json.bytesize > 100.kilobytes
      errors.add(:changes_made, "is too large (max 100KB)")
    end
  end
end

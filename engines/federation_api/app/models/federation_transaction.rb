# Records a cross-platform time transfer between this TimeOverflow
# instance and a federation partner.
#
# For inbound transfers: a remote user sends time to a local member
# For outbound transfers: a local member sends time to a remote user
#
# The local Transfer record (if created) is linked via transfer_id.
# The remote platform's transaction ID is stored in external_transaction_id.
#
class FederationTransaction < ActiveRecord::Base
  belongs_to :federation_partner
  belongs_to :transfer, optional: true

  STATUSES = %w[pending completed cancelled disputed].freeze
  DIRECTIONS = %w[inbound outbound].freeze

  validates :direction, presence: true, inclusion: { in: DIRECTIONS }
  validates :amount, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 360_000 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :remote_user_identifier, presence: true, length: { maximum: 255 }
  validates :external_transaction_id, uniqueness: { scope: :federation_partner_id },
            allow_nil: true

  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }
  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }
  scope :for_organization, ->(org_id) { where(organization_id: org_id) }

  # Auto-populate organization_id from the local account on create.
  before_validation :denormalize_organization_id, on: :create

  private def denormalize_organization_id
    return if organization_id.present?
    if local_account_id.present?
      self.organization_id = Account.where(id: local_account_id).pick(:organization_id)
    end
  end
  public

  def complete!(local_transfer: nil)
    # Idempotency guard — safe to call twice (e.g. webhook delivery retries).
    return if completed?

    # State guard — only pending transactions can be completed.
    unless pending?
      raise "Cannot complete a #{status} federation transaction (id=#{id})"
    end

    attrs = { status: "completed", completed_at: Time.current }
    attrs[:transfer] = local_transfer if local_transfer.present?
    update!(attrs)
  end

  def cancel!(reason: nil)
    # Guard: only pending transactions can be cancelled.
    unless pending?
      raise "Cannot cancel a #{status} federation transaction (id=#{id})"
    end

    update!(
      status: "cancelled",
      cancelled_at: Time.current,
      metadata: (metadata || {}).merge("cancellation_reason" => reason)
    )
  end

  def pending?
    status == "pending"
  end

  def completed?
    status == "completed"
  end

  def cancelled?
    status == "cancelled"
  end

  def inbound?
    direction == "inbound"
  end

  def outbound?
    direction == "outbound"
  end
end

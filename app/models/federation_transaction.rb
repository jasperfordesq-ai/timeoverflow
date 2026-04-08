# Records a cross-platform time transfer between this TimeOverflow
# instance and a federation partner.
#
# For inbound transfers: a remote user sends time to a local member
# For outbound transfers: a local member sends time to a remote user
#
# The local Transfer record (if created) is linked via transfer_id.
# The remote platform's transaction ID is stored in external_transaction_id.
#
class FederationTransaction < ApplicationRecord
  belongs_to :federation_partner
  belongs_to :transfer, optional: true

  STATUSES = %w[pending completed cancelled disputed].freeze
  DIRECTIONS = %w[inbound outbound].freeze

  validates :direction, presence: true, inclusion: { in: DIRECTIONS }
  validates :amount, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 360_000 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :remote_user_identifier, presence: true
  validates :external_transaction_id, uniqueness: { scope: :federation_partner_id },
            allow_nil: true

  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }
  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }

  def complete!(local_transfer: nil)
    update!(
      status: "completed",
      transfer: local_transfer,
      completed_at: Time.current
    )
  end

  def cancel!(reason: nil)
    update!(
      status: "cancelled",
      cancelled_at: Time.current,
      metadata: metadata.merge("cancellation_reason" => reason)
    )
  end

  def pending?
    status == "pending"
  end

  def completed?
    status == "completed"
  end
end

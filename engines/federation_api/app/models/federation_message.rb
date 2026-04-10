# A cross-platform federation message between a local TimeOverflow
# member and a remote user on a federation partner platform.
#
# Inbound messages are received via the /api/v1/messages endpoint
# or via a "message.sent" webhook event.
# Outbound messages are initiated by local members and delivered
# to the partner via webhook.
#
class FederationMessage < ActiveRecord::Base
  belongs_to :federation_partner
  belongs_to :member, foreign_key: :local_member_id, optional: true

  STATUSES = %w[pending delivered read failed].freeze
  DIRECTIONS = %w[inbound outbound].freeze

  validates :direction, presence: true, inclusion: { in: DIRECTIONS }
  validates :body, presence: true
  validates :remote_user_identifier, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :organization_id, presence: true
  validates :external_message_id,
            uniqueness: { scope: :federation_partner_id },
            allow_nil: true

  scope :inbound,   -> { where(direction: "inbound") }
  scope :outbound,  -> { where(direction: "outbound") }
  scope :pending,   -> { where(status: "pending") }
  scope :delivered,  -> { where(status: "delivered") }
  scope :for_member, ->(member_id) { where(local_member_id: member_id) }
  scope :for_organization, ->(org_id) { where(organization_id: org_id) }

  def deliver!
    update!(status: "delivered", delivered_at: Time.current)
  end

  def mark_read!
    update!(read_at: Time.current) unless read_at.present?
  end

  def inbound?
    direction == "inbound"
  end

  def outbound?
    direction == "outbound"
  end
end

# Audit log for webhook deliveries to/from federation partners.
#
class FederationWebhookLog < ApplicationRecord
  belongs_to :federation_partner

  STATUSES = %w[pending success failed].freeze
  DIRECTIONS = %w[inbound outbound].freeze

  validates :event_type, presence: true
  validates :direction, presence: true, inclusion: { in: DIRECTIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc).limit(100) }
  scope :failed, -> { where(status: "failed") }
  scope :retryable, -> { failed.where("created_at > ?", 24.hours.ago).limit(50) }
end

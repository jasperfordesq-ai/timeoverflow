# Stores the results of each reconciliation job run for admin visibility.
#
class FederationReconciliationRun < ActiveRecord::Base
  STATUSES = %w[completed critical failed].freeze

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :critical_count, :warning_count, :total_findings,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  scope :recent, -> { order(created_at: :desc) }

  def duration
    return nil unless started_at && finished_at
    finished_at - started_at
  end

  def healthy?
    critical_count == 0
  end
end

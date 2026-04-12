# Stores the results of each reconciliation job run for admin visibility.
#
class FederationReconciliationRun < ActiveRecord::Base
  scope :recent, -> { order(created_at: :desc) }

  def duration
    return nil unless started_at && finished_at
    finished_at - started_at
  end

  def healthy?
    critical_count == 0
  end
end

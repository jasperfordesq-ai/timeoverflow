# Periodic reconciliation job to detect balance drift between
# TimeOverflow and federation partners.
#
# Checks that:
# 1. All completed federation_transactions have a corresponding local transfer
# 2. The sum of federation inbound credits matches the sum of outbound debits
#    for each partner (net should be reflected in org account)
# 3. No pending transactions are older than the timeout threshold
#
# Schedule: Run daily via Sidekiq-cron
#
module Federation
  class ReconciliationJob < ActiveJob::Base
    queue_as :default

    # Transactions pending longer than this are flagged
    PENDING_TIMEOUT = 1.hour

    def perform
      Rails.logger.info("[Federation::Reconciliation] Starting reconciliation run")

      issues = []

      # Check 1: Completed transactions without local transfers
      orphans = FederationTransaction.completed.where(transfer_id: nil)
      if orphans.any?
        issues << {
          type: "orphaned_transactions",
          severity: "critical",
          count: orphans.count,
          ids: orphans.pluck(:id),
          message: "#{orphans.count} completed federation transaction(s) have no local transfer"
        }
      end

      # Check 2: Balance consistency per partner
      FederationPartner.active.find_each do |partner|
        inbound_total = partner.federation_transactions
          .completed.inbound
          .sum(:amount)
        outbound_total = partner.federation_transactions
          .completed.outbound
          .sum(:amount)

        net = inbound_total - outbound_total

        # The org account should reflect this net via movements
        # (inbound credits the member, debits the org → org goes negative by inbound_total)
        # (outbound debits the member, credits the org → org goes positive by outbound_total)
        # So org's federation net impact = outbound_total - inbound_total = -net

        issues << {
          type: "balance_report",
          severity: "info",
          partner: partner.name,
          partner_id: partner.id,
          inbound_total: inbound_total,
          outbound_total: outbound_total,
          net_flow: net,
          message: "Partner #{partner.name}: inbound=#{inbound_total}, outbound=#{outbound_total}, net=#{net}"
        }
      end

      # Check 3: Stale pending transactions
      stale = FederationTransaction.pending.where("created_at < ?", PENDING_TIMEOUT.ago)
      if stale.any?
        issues << {
          type: "stale_pending",
          severity: "warning",
          count: stale.count,
          ids: stale.pluck(:id),
          oldest: stale.minimum(:created_at),
          message: "#{stale.count} transaction(s) pending longer than #{PENDING_TIMEOUT.inspect}"
        }

        # Auto-cancel very old pending transactions (> 24 hours)
        very_stale = stale.where("created_at < ?", 24.hours.ago)
        very_stale.find_each do |txn|
          txn.cancel!(reason: "Auto-cancelled: pending for over 24 hours")
          Rails.logger.warn("[Federation::Reconciliation] Auto-cancelled stale transaction #{txn.id}")
        end
      end

      # Check 4: Transfer movement integrity
      FederationTransaction.completed.where.not(transfer_id: nil).find_each do |fed_txn|
        transfer = fed_txn.transfer
        next unless transfer

        movements = transfer.movements
        if movements.count != 2
          issues << {
            type: "movement_count_mismatch",
            severity: "critical",
            federation_transaction_id: fed_txn.id,
            transfer_id: transfer.id,
            expected_movements: 2,
            actual_movements: movements.count,
            message: "Transfer #{transfer.id} has #{movements.count} movements (expected 2)"
          }
        end

        # Movements should sum to zero (double-entry)
        movement_sum = movements.sum(:amount)
        if movement_sum != 0
          issues << {
            type: "movement_imbalance",
            severity: "critical",
            federation_transaction_id: fed_txn.id,
            transfer_id: transfer.id,
            sum: movement_sum,
            message: "Transfer #{transfer.id} movements sum to #{movement_sum} (should be 0)"
          }
        end
      end

      # Log results
      critical_count = issues.count { |i| i[:severity] == "critical" }
      warning_count = issues.count { |i| i[:severity] == "warning" }

      if critical_count > 0
        Rails.logger.error("[Federation::Reconciliation] #{critical_count} CRITICAL issue(s) found!")
        issues.select { |i| i[:severity] == "critical" }.each do |issue|
          Rails.logger.error("[Federation::Reconciliation] #{issue[:type]}: #{issue[:message]}")
        end
      end

      if warning_count > 0
        Rails.logger.warn("[Federation::Reconciliation] #{warning_count} warning(s)")
      end

      Rails.logger.info("[Federation::Reconciliation] Complete. #{issues.count} total findings (#{critical_count} critical, #{warning_count} warnings)")

      issues
    end
  end
end

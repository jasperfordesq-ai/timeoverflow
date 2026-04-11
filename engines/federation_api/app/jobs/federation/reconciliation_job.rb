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
    queue_as :federation

    # M4: Two distinct timeouts with different semantics.
    # STALE_WARNING_TIMEOUT — pending transactions older than this are flagged in the report.
    # REVERSAL_TIMEOUT — pending transactions older than this are auto-cancelled and reversed.
    STALE_WARNING_TIMEOUT = 1.hour
    REVERSAL_TIMEOUT      = 24.hours

    def perform
      Rails.logger.info("[Federation::Reconciliation] Starting reconciliation run")

      issues = []

      # Check 1: Completed transactions without local transfers.
      # H8: Move these to "disputed" so they are visible and don't look healthy.
      orphans = FederationTransaction.completed.where(transfer_id: nil)
      if orphans.any?
        orphan_ids = orphans.pluck(:id)
        orphans.find_each do |txn|
          begin
            txn.update!(
              status: "disputed",
              metadata: (txn.metadata || {}).merge(
                "dispute_reason" => "Completed with no local transfer — data integrity error",
                "disputed_at"    => Time.current.iso8601
              )
            )
            Rails.logger.error("[Federation::Reconciliation] Moved orphaned completed fed_txn #{txn.id} to disputed")
          rescue => e
            Rails.logger.error("[Federation::Reconciliation] Failed to dispute orphaned fed_txn #{txn.id}: #{e.class}: #{e.message}")
          end
        end
        issues << {
          type: "orphaned_transactions",
          severity: "critical",
          count: orphan_ids.count,
          ids: orphan_ids,
          message: "#{orphan_ids.count} completed federation transaction(s) had no local transfer — moved to disputed"
        }
      end

      # Check 2: Balance consistency per partner, broken down by organization.
      # Groups by (partner, org) so multi-org instances see per-timebank drift.
      FederationPartner.active.find_each do |partner|
        # Group completed transactions by organization_id
        org_groups = partner.federation_transactions.completed
          .group(:organization_id, :direction)
          .sum(:amount)

        # Pivot into per-org summaries
        org_ids = org_groups.keys.map(&:first).uniq.compact
        org_ids.each do |org_id|
          inbound  = org_groups[[org_id, "inbound"]]  || 0
          outbound = org_groups[[org_id, "outbound"]] || 0
          net = inbound - outbound

          issues << {
            type: "balance_report",
            severity: "info",
            partner: partner.name,
            partner_id: partner.id,
            organization_id: org_id,
            inbound_total: inbound,
            outbound_total: outbound,
            net_flow: net,
            message: "Partner #{partner.name} / Org #{org_id}: in=#{inbound}, out=#{outbound}, net=#{net}"
          }
        end

        # Also report transactions with no org_id (legacy or data issue)
        unscoped_in  = org_groups[[nil, "inbound"]]  || 0
        unscoped_out = org_groups[[nil, "outbound"]] || 0
        if unscoped_in > 0 || unscoped_out > 0
          issues << {
            type: "unscoped_transactions",
            severity: "warning",
            partner: partner.name,
            partner_id: partner.id,
            inbound_total: unscoped_in,
            outbound_total: unscoped_out,
            message: "Partner #{partner.name} has #{unscoped_in + unscoped_out} transaction(s) with no organization_id"
          }
        end
      end

      # Check 3: Stale pending transactions (two thresholds — see constants above)
      stale = FederationTransaction.pending.where("created_at < ?", STALE_WARNING_TIMEOUT.ago)
      if stale.any?
        issues << {
          type: "stale_pending",
          severity: "warning",
          count: stale.count,
          ids: stale.pluck(:id),
          oldest: stale.minimum(:created_at),
          message: "#{stale.count} transaction(s) pending longer than #{STALE_WARNING_TIMEOUT.inspect}"
        }

        # Auto-cancel and reverse transactions older than REVERSAL_TIMEOUT
        very_stale = stale.where("created_at < ?", REVERSAL_TIMEOUT.ago)
        very_stale.find_each do |txn|
          begin
            ActiveRecord::Base.transaction do
              # Lock the row to prevent concurrent reconciliation runs from
              # processing the same transaction (double-reversal prevention).
              txn = FederationTransaction.lock.find_by(id: txn.id)
              next unless txn&.pending?  # skip if already processed by another worker
              # For outbound transactions: the local Transfer was committed when the
              # transaction was created (member was debited). If the webhook delivery
              # failed and we're now cancelling, we must reverse that debit so the
              # member's balance is restored.
              if txn.outbound?
                if txn.transfer.present?
                  original = txn.transfer
                  # Transfer#source and #destination are attr_accessors (not DB columns)
                  # and are nil when loaded from the database. Use movements instead.
                  debit_movement  = original.movements.find_by("amount < 0") # source
                  credit_movement = original.movements.find_by("amount > 0") # destination
                  unless debit_movement && credit_movement
                    raise "Cannot reverse transfer #{original.id}: missing movements"
                  end
                  reversal = Transfer.new
                  reversal.source      = credit_movement.account_id  # was destination → now source
                  reversal.destination = debit_movement.account_id   # was source → now destination
                  reversal.amount      = txn.amount
                  reversal.reason      = "[Federation Reversal] #{txn.reason} — webhook delivery failed"
                  reversal.save!

                  # Link reversal to the federation transaction metadata for audit trail
                  txn.update!(metadata: (txn.metadata || {}).merge("reversal_transfer_id" => reversal.id))
                  Rails.logger.warn("[Federation::Reconciliation] Reversed transfer #{original.id} via reversal #{reversal.id} for stale outbound fed_txn #{txn.id}")
                else
                  # H8: Outbound txn has no Transfer — the debit was never committed,
                  # or the link was lost. Move to disputed so a human can investigate
                  # rather than silently cancelling without reversing.
                  txn.update!(
                    status: "disputed",
                    metadata: (txn.metadata || {}).merge(
                      "dispute_reason" => "Stale outbound pending with no linked transfer — cannot auto-reverse",
                      "disputed_at"    => Time.current.iso8601
                    )
                  )
                  msg = "Stale outbound fed_txn #{txn.id} has no Transfer — moved to disputed, requires manual review"
                  Rails.logger.error("[Federation::Reconciliation] #{msg}")
                  trigger_alert!(msg)
                  next # skip cancel! — already moved to disputed
                end
              end

              txn.cancel!(reason: "Auto-cancelled: pending for over #{REVERSAL_TIMEOUT.inspect}")
            end

            Rails.logger.warn("[Federation::Reconciliation] Auto-cancelled stale #{txn.direction} transaction #{txn.id}")

            # Notify the partner about the cancellation
            Federation::WebhookSender.send_async(
              partner: txn.federation_partner,
              event: "transaction.cancelled",
              payload: {
                external_transaction_id: txn.external_transaction_id,
                federation_transaction_id: txn.id,
                reason: "Auto-cancelled: pending for over #{REVERSAL_TIMEOUT.inspect}",
                cancelled_at: txn.cancelled_at&.iso8601
              }
            )
          rescue => e
            Rails.logger.error("[Federation::Reconciliation] Failed to cancel/reverse stale fed_txn #{txn.id}: #{e.class}: #{e.message}")
          end
        end
      end

      # Check 4: Transfer movement integrity (eager-load to avoid N+1)
      FederationTransaction.completed.where.not(transfer_id: nil)
        .includes(transfer: :movements).find_each do |fed_txn|
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
          trigger_alert!("#{issue[:type]}: #{issue[:message]}")
        end
      end

      if warning_count > 0
        Rails.logger.warn("[Federation::Reconciliation] #{warning_count} warning(s)")
      end

      Rails.logger.info("[Federation::Reconciliation] Complete. #{issues.count} total findings (#{critical_count} critical, #{warning_count} warnings)")

      issues
    end

    private

    # M7: Alerting hook for critical reconciliation findings.
    # Logs at FATAL level so log aggregators (CloudWatch, Datadog, etc.) can filter
    # for "[ALERT]" and page on-call. Add external integrations here.
    def trigger_alert!(message)
      Rails.logger.fatal("[Federation::Reconciliation][ALERT] #{message}")
      # Hook: uncomment and configure external alerting as needed, e.g.:
      # Sentry.capture_message(message, level: :fatal) rescue nil
      # SlackNotifier.ping("#federation-alerts", message) rescue nil
    end
  end
end

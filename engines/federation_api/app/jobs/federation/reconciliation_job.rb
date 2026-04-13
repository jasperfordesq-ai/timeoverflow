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
    # stale_warning_timeout — pending transactions older than this are flagged in the report.
    # reversal_timeout — pending transactions older than this are auto-cancelled and reversed.
    # Evaluated at runtime (not class load time) so ENV changes take effect without restart.

    def perform
      Rails.logger.info("[Federation::Reconciliation] Starting reconciliation run")
      started_at = Time.current

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
              metadata: (txn.metadata || {}).deep_merge(
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
      stale = FederationTransaction.pending.where("created_at < ?", Time.current - stale_warning_timeout)
      if stale.any?
        issues << {
          type: "stale_pending",
          severity: "warning",
          count: stale.count,
          ids: stale.pluck(:id),
          oldest: stale.minimum(:created_at),
          message: "#{stale.count} transaction(s) pending longer than #{stale_warning_timeout.inspect}"
        }

        # Auto-cancel and reverse transactions older than reversal_timeout
        very_stale = stale.where("created_at < ?", Time.current - reversal_timeout)
        very_stale.find_each do |txn|
          begin
            # Track outcome across the transaction block boundary.
            # `next` inside the transaction block exits to this scope, so
            # these flags prevent NoMethodError on nil and incorrect logging.
            txn_cancelled = false
            original_txn_id = txn.id

            ActiveRecord::Base.transaction do
              # Lock the row with FOR UPDATE SKIP LOCKED to prevent concurrent
              # reconciliation runs from processing the same transaction (double-
              # reversal prevention). SKIP LOCKED avoids blocking if another
              # worker already holds the lock — the row is simply skipped.
              txn = FederationTransaction.where(id: original_txn_id, status: "pending")
                                         .lock("FOR UPDATE SKIP LOCKED").first
              next unless txn  # skip if already processed or locked by another worker

              # Idempotency: skip if already reversed by a prior run
              if txn.metadata&.dig("reversal_transfer_id").present?
                Rails.logger.info("[Federation::Reconciliation] Already reversed for fed_txn #{txn.id}, skipping")
                txn.cancel!(reason: "Auto-cancelled: already reversed")
                txn_cancelled = true
                next
              end

              # For outbound transactions: the local Transfer was committed when the
              # transaction was created (member was debited). If the webhook delivery
              # failed and we're now cancelling, we must reverse that debit so the
              # member's balance is restored.
              # Reverse the local Transfer for stale pending transactions.
              # Outbound: member was debited when the transaction was created;
              #   reversal re-credits the member since the remote partner never acknowledged.
              # Inbound: member was credited when the transaction was created;
              #   reversal re-debits the member since the transaction was never confirmed.
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
                reversal.reason      = "[Federation Reversal] #{txn.reason} — stale #{txn.direction} transaction auto-cancelled"
                reversal.save!

                # Link reversal to the federation transaction metadata for audit trail
                txn.update!(metadata: (txn.metadata || {}).deep_merge("reversal_transfer_id" => reversal.id))
                Rails.logger.warn("[Federation::Reconciliation] Reversed transfer #{original.id} via reversal #{reversal.id} for stale #{txn.direction} fed_txn #{txn.id}")
              elsif txn.outbound?
                # H8: Outbound txn has no Transfer — the debit was never committed,
                # or the link was lost. Move to disputed so a human can investigate
                # rather than silently cancelling without reversing.
                txn.update!(
                  status: "disputed",
                  metadata: (txn.metadata || {}).deep_merge(
                    "dispute_reason" => "Stale outbound pending with no linked transfer — cannot auto-reverse",
                    "disputed_at"    => Time.current.iso8601
                  )
                )
                msg = "Stale outbound fed_txn #{txn.id} has no Transfer — moved to disputed, requires manual review"
                Rails.logger.error("[Federation::Reconciliation] #{msg}")
                trigger_alert!(msg)
                next # skip cancel! — already moved to disputed
              end
              # Inbound with no transfer: no local balance was moved, safe to just cancel.

              txn.cancel!(reason: "Auto-cancelled: pending for over #{reversal_timeout.inspect}")
              txn_cancelled = true
            end

            # Only log and notify if the transaction was actually cancelled
            # (not skipped via SKIP LOCKED, not moved to disputed).
            next unless txn_cancelled && txn

            Rails.logger.warn("[Federation::Reconciliation] Auto-cancelled stale #{txn.direction} transaction #{txn.id}")

            # Notify the partner about the cancellation
            Federation::WebhookSender.send_async(
              partner: txn.federation_partner,
              event: "transaction.cancelled",
              payload: {
                external_transaction_id: txn.external_transaction_id,
                federation_transaction_id: txn.id,
                reason: "Auto-cancelled: pending for over #{reversal_timeout.inspect}",
                cancelled_at: txn.cancelled_at&.iso8601
              }
            )
          rescue => e
            Rails.logger.error("[Federation::Reconciliation] Failed to cancel/reverse stale fed_txn #{original_txn_id}: #{e.class}: #{e.message}")
          end
        end
      end

      # Check 4: Transfer movement integrity (eager-load to avoid N+1)
      # Pre-build org_id -> account_ids lookup to avoid N+1 in Check 4b.
      org_account_ids_cache = {}

      FederationTransaction.completed.where.not(transfer_id: nil)
        .includes(transfer: :movements).find_each do |fed_txn|
        transfer = fed_txn.transfer
        next unless transfer

        movements = transfer.movements.to_a
        if movements.size != 2
          begin
            fed_txn.update!(
              status: "disputed",
              metadata: (fed_txn.metadata || {}).deep_merge(
                "dispute_reason" => "Movement count mismatch: #{movements.size} instead of 2",
                "disputed_at"    => Time.current.iso8601
              )
            )
          rescue => e
            Rails.logger.error("[Federation::Reconciliation] Failed to dispute fed_txn #{fed_txn.id} for movement count mismatch: #{e.class}: #{e.message}")
          end

          issues << {
            type: "movement_count_mismatch",
            severity: "critical",
            federation_transaction_id: fed_txn.id,
            transfer_id: transfer.id,
            expected_movements: 2,
            actual_movements: movements.size,
            message: "Transfer #{transfer.id} has #{movements.size} movements (expected 2)"
          }
        end

        # Movements should sum to zero (double-entry)
        movement_sum = movements.sum(&:amount)
        if movement_sum != 0
          # Mark the federation transaction metadata with corruption flag
          # so admin dashboards can surface these immediately.
          begin
            fed_txn.update!(
              status: "disputed",
              metadata: (fed_txn.metadata || {}).deep_merge(
                "corrupted" => true,
                "corruption_reason" => "Movement imbalance: sum=#{movement_sum}, count=#{movements.size}",
                "corruption_detected_at" => Time.current.iso8601,
                "dispute_reason" => "Movement imbalance: sum=#{movement_sum}",
                "disputed_at" => Time.current.iso8601
              )
            )
          rescue => e
            Rails.logger.error("[Federation::Reconciliation] Failed to mark fed_txn #{fed_txn.id} as corrupted: #{e.class}: #{e.message}")
          end

          issues << {
            type: "movement_imbalance",
            severity: "critical",
            federation_transaction_id: fed_txn.id,
            transfer_id: transfer.id,
            sum: movement_sum,
            message: "Transfer #{transfer.id} movements sum to #{movement_sum} (should be 0)"
          }
        end

        # Check 4b: Account ownership — verify at least one movement's account
        # belongs to the federation transaction's organization.
        if fed_txn.organization_id.present? && movements.size == 2
          org_account_ids_cache[fed_txn.organization_id] ||= Account.where(organization_id: fed_txn.organization_id).pluck(:id)
          movement_account_ids = movements.map(&:account_id)
          unless (movement_account_ids & org_account_ids_cache[fed_txn.organization_id]).any?
            issues << {
              type: "account_ownership_mismatch",
              severity: "critical",
              federation_transaction_id: fed_txn.id,
              transfer_id: transfer.id,
              organization_id: fed_txn.organization_id,
              message: "Transfer #{transfer.id} has no movement accounts belonging to organization #{fed_txn.organization_id}"
            }
          end
        end
      end

      # Check 5: Purge stale webhook nonces older than 1 hour.
      # The nonce table prevents replay attacks but grows unbounded without cleanup.
      nonce_cutoff = 1.hour.ago
      stale_nonces = FederationWebhookLog.where.not(request_nonce: nil)
                                          .where("created_at < ?", nonce_cutoff)
      purged_count = stale_nonces.update_all(request_nonce: nil)
      issues << {
        type: "nonce_purge",
        severity: "info",
        count: purged_count,
        message: "Purged #{purged_count} stale webhook nonce(s) older than #{nonce_cutoff}"
      }
      if purged_count > 0
        Rails.logger.info("[Federation::Reconciliation] Cleared #{purged_count} stale webhook nonces older than #{nonce_cutoff}")
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

      # Persist run results for admin visibility
      begin
        FederationReconciliationRun.create!(
          status: critical_count > 0 ? "critical" : "completed",
          critical_count: critical_count,
          warning_count: warning_count,
          total_findings: issues.count,
          issues: issues,
          started_at: started_at,
          finished_at: Time.current
        )
      rescue => persist_err
        Rails.logger.error("[Federation::Reconciliation] Failed to persist run record: #{persist_err.class}: #{persist_err.message}")
        # Non-fatal: the reconciliation checks themselves succeeded; only the
        # result record failed to save. Log and continue rather than retrying
        # the entire job (which would re-run all checks).
      end
    rescue => e
      # Record the failed run so admins can see it in the dashboard.
      begin
        FederationReconciliationRun.create!(
          status: "failed",
          critical_count: 0,
          warning_count: 0,
          total_findings: 0,
          issues: [{ type: "job_error", severity: "critical", message: "#{e.class}: #{e.message}" }],
          started_at: started_at,
          finished_at: Time.current
        )
      rescue => persist_err
        Rails.logger.error("[Federation::Reconciliation] Could not persist failed run record: #{persist_err.message}")
      end
      Rails.logger.error("[Federation::Reconciliation] Job failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
      raise # Let Sidekiq retry
    end

    private

    def stale_warning_timeout
      ENV.fetch("FEDERATION_STALE_WARNING_TIMEOUT", "3600").to_i.seconds
    end

    def reversal_timeout
      ENV.fetch("FEDERATION_REVERSAL_TIMEOUT", "86400").to_i.seconds
    end

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

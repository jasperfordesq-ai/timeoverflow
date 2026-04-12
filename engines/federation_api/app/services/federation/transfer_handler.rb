# Handles cross-platform time transfers between TimeOverflow and
# federation partners.
#
# Inbound: remote user sends time → local member receives
# Outbound: local member sends time → remote user receives
#
# Outbound transaction lifecycle:
#   1. Create FederationTransaction (status: pending) + local Transfer atomically
#   2. Queue webhook to notify remote partner (async, with retries)
#   3. WebhookDeliveryJob calls complete! after confirmed delivery
#   4. If delivery fails after all retries, ReconciliationJob reverses the
#      local Transfer and cancels the FederationTransaction after 24 hours.
#
module Federation
  class TransferHandler
    # Handle an inbound transfer request from a webhook
    def self.handle_inbound_request(partner, payload)
      # Validate required fields
      %w[local_organization_id remote_user_identifier amount external_transaction_id].each do |field|
        raise ArgumentError, "Missing required field: #{field}" if payload[field].blank?
      end
      raise ArgumentError, "Must provide local_member_email or local_member_uid" if payload["local_member_email"].blank? && payload["local_member_uid"].blank?

      amount = payload["amount"].to_i
      raise ArgumentError, "Amount must be positive" if amount <= 0

      # H6: Enforce the configured max transfer amount for inbound transfers.
      # The API endpoint validates outbound amounts; this ensures the same cap
      # applies when a remote partner sends a webhook-initiated inbound transfer.
      max_amount = begin
        v = Rails.application.config.federation.max_transfer_amount
        v.to_i > 0 ? v.to_i : 360_000
      rescue NoMethodError, StandardError
        360_000
      end
      if amount > max_amount
        raise ArgumentError, "Amount #{amount} exceeds maximum (#{max_amount} seconds)"
      end

      external_transaction_id = payload["external_transaction_id"]

      handler = new(partner: partner)
      reason = payload["reason"]
      reason = reason.to_s[0, 500] if reason.present?

      handler.process_inbound(
        external_transaction_id: external_transaction_id,
        local_member_email: payload["local_member_email"],
        local_member_uid: payload["local_member_uid"],
        local_organization_id: payload["local_organization_id"],
        remote_user_identifier: payload["remote_user_identifier"],
        amount: amount,
        reason: reason
      )
    end

    def initialize(partner:)
      @partner = partner
    end

    # Process an inbound transfer (remote → local).
    # Commits atomically; webhook notification is post-commit (async with retries).
    def process_inbound(external_transaction_id:, local_member_email: nil,
                        local_member_uid: nil, local_organization_id:,
                        remote_user_identifier:, amount:, reason: nil)
      validate_partner_can_transact!

      org = Organization.find(local_organization_id)
      raise ArgumentError, "Organization #{org.id} has no account" unless org.account
      member = find_local_member(org, email: local_member_email, member_uid: local_member_uid)

      fed_txn = nil

      begin
        ActiveRecord::Base.transaction(isolation: :repeatable_read) do
          # IDEMPOTENCY fast-path: moved inside the transaction to eliminate the
          # TOCTOU window. Common duplicates return a clean success without
          # progressing further.
          if external_transaction_id.present?
            existing = FederationTransaction.find_by(
              federation_partner: @partner,
              external_transaction_id: external_transaction_id
            )
            return existing if existing
          end

          # H7: Lock-based idempotency check — if a concurrent request is in
          # flight (INSERT not yet committed), the FOR UPDATE lock waits for it
          # to resolve, then we check again. SKIP LOCKED avoids deadlocks.
          if external_transaction_id.present?
            locked_existing = FederationTransaction.where(
              federation_partner: @partner,
              external_transaction_id: external_transaction_id
            ).lock("FOR UPDATE SKIP LOCKED").first
            return locked_existing if locked_existing
          end

          fed_txn = FederationTransaction.create!(
            federation_partner: @partner,
            external_transaction_id: external_transaction_id,
            direction: "inbound",
            local_account_id: member.account.id,
            organization_id: org.id,
            remote_user_identifier: remote_user_identifier,
            amount: amount,
            reason: reason
          )

          # Credit local member from org's federation pool
          transfer = Transfer.new
          transfer.source = org.account.id
          transfer.destination = member.account.id
          transfer.amount = amount
          transfer.reason = "[Federation] #{reason.presence || "Cross-platform transfer"}"
          transfer.save!

          # Synchronous double-entry validation: verify the transfer
          # created exactly 2 movements summing to zero before proceeding.
          # NOTE: Must raise a real exception (not ActiveRecord::Rollback) so the
          # error propagates outside the transaction block. Rollback is silently
          # swallowed by the transaction block and execution would continue with
          # a rolled-back fed_txn — corrupting state.
          movements = transfer.movements.reload
          unless movements.size == 2 && movements.sum(&:amount) == 0
            raise StandardError, "Double-entry violation: #{movements.size} movements, sum=#{movements.sum(&:amount)}"
          end

          fed_txn.complete!(local_transfer: transfer)
        end
      rescue ActiveRecord::RecordNotUnique
        # Race condition: another request committed between our lock check and INSERT.
        # The DB unique constraint is the final safety net — fetch the winner.
        existing = FederationTransaction.find_by(
          federation_partner: @partner,
          external_transaction_id: external_transaction_id
        )
        return existing if existing
        raise ActiveRecord::RecordNotUnique, "Duplicate federation transaction for partner #{@partner.id} with external_transaction_id=#{external_transaction_id}, but no matching record found"
      end

      # Notify the local member about the received transfer.
      Federation::NotificationService.notify(
        member: member,
        event_type: :transfer_received,
        data: { amount: amount, remote_user_identifier: remote_user_identifier, reason: reason, partner_name: @partner.name }
      )

      # Notify partner AFTER transaction commits (async, retries on failure).
      # If delivery ultimately fails the transaction record is already committed
      # and the member's balance is correct — the partner will reconcile via
      # their own timeout/reconciliation logic.
      WebhookSender.send_async(
        partner: @partner,
        event: "transaction.completed",
        payload: {
          external_transaction_id: external_transaction_id,
          federation_transaction_id: fed_txn.id,
          status: "completed"
        }
      )

      fed_txn
    end

    # Initiate an outbound transfer (local → remote).
    #
    # The local debit is committed immediately but the FederationTransaction
    # is left as "pending" until the remote partner acknowledges the webhook.
    # WebhookDeliveryJob calls complete! on successful delivery. If all
    # retries fail, ReconciliationJob reverses the transfer after 24 hours.
    def initiate_outbound(local_account:, remote_user_identifier:, amount:, reason: nil)
      validate_partner_can_transact!

      org = local_account.organization
      raise ArgumentError, "Account has no associated organization" unless org
      raise ArgumentError, "Organization #{org.id} has no account" unless org.account

      # Fix #6: Generate a stable external_transaction_id NOW so that:
      # (a) the webhook payload and local record use the same reference, and
      # (b) if Nexus echoes it back in cancellation/completion webhooks,
      #     we can find the correct local FederationTransaction.
      external_transaction_id = SecureRandom.uuid

      fed_txn = nil
      local_transfer = nil

      ActiveRecord::Base.transaction(isolation: :repeatable_read) do
        fed_txn = FederationTransaction.create!(
          federation_partner: @partner,
          external_transaction_id: external_transaction_id,
          direction: "outbound",
          local_account_id: local_account.id,
          organization_id: org.id,
          remote_user_identifier: remote_user_identifier,
          amount: amount,
          reason: reason
          # status defaults to "pending" — NOT completed yet
        )

        # Debit local member to org's federation pool
        local_transfer = Transfer.new
        local_transfer.source = local_account.id
        local_transfer.destination = org.account.id
        local_transfer.amount = amount
        local_transfer.reason = "[Federation] #{reason.presence || "Cross-platform transfer"}"
        local_transfer.save!

        # Link transfer to fed_txn so ReconciliationJob can find it for reversal,
        # but leave status as "pending" — complete! is called by WebhookDeliveryJob.
        fed_txn.update!(
          transfer: local_transfer,
          metadata: (fed_txn.metadata || {}).merge(
            "local_transfer_id" => local_transfer.id,
            "webhook_queued_at" => nil
          )
        )
      end

      # Request remote partner to credit the remote user AFTER commit.
      # Pass fed_txn_id so the delivery job can call complete! on success.
      WebhookSender.send_async(
        partner: @partner,
        event: "transaction.requested",
        fed_txn_id: fed_txn.id,
        payload: {
          external_transaction_id: external_transaction_id,
          remote_user_identifier: remote_user_identifier,
          amount: amount,
          reason: reason,
          source_platform: "timeoverflow",
          source_organization_id: org.id,
          source_organization_name: org.name
        }
      )

      # Use update (not update!) — metadata timestamp is informational;
      # failure here should not crash the transfer flow.
      unless fed_txn.update(metadata: (fed_txn.metadata || {}).merge("webhook_queued_at" => Time.current.iso8601))
        Rails.logger.warn("[Federation::TransferHandler] Failed to update webhook_queued_at metadata for fed_txn #{fed_txn.id}")
      end

      fed_txn
    end

    private

    def validate_partner_can_transact!
      raise ArgumentError, "Partner cannot transact" unless @partner.can_transact?
    end

    def find_local_member(org, email: nil, member_uid: nil)
      member = if member_uid.present?
                 org.members.active.find_by!(member_uid: member_uid)
               elsif email.present?
                 user = User.find_by!(email: email)
                 org.members.active.find_by!(user: user)
               else
                 raise ArgumentError, "Must provide local_member_email or local_member_uid"
               end

      raise ArgumentError, "Member account not found" unless member.account

      # Fix #12: verify account ownership — prevents cross-org balance moves
      # if a user somehow has accounts spanning multiple organizations.
      unless member.account.organization_id == org.id
        raise ArgumentError, "Member account does not belong to organization #{org.id}"
      end

      # Federation consent check: member must have opted in to receive transfers.
      unless Federation::AccessControl.member_can_receive?(member, partner: @partner)
        raise ArgumentError, "Member has not opted in to federation transfers"
      end

      member
    end
  end
end

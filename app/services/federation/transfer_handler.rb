# Handles cross-platform time transfers between TimeOverflow and
# federation partners.
#
# Inbound: remote user sends time → local member receives
# Outbound: local member sends time → remote user receives
#
module Federation
  class TransferHandler
    # Handle an inbound transfer request from a webhook
    def self.handle_inbound_request(partner, payload)
      # Validate required fields
      %w[local_organization_id remote_user_identifier amount].each do |field|
        raise ArgumentError, "Missing required field: #{field}" if payload[field].blank?
      end
      raise ArgumentError, "Must provide local_member_email or local_member_uid" if payload["local_member_email"].blank? && payload["local_member_uid"].blank?

      amount = payload["amount"].to_i
      raise ArgumentError, "Amount must be positive" if amount <= 0

      handler = new(partner: partner)
      handler.process_inbound(
        external_transaction_id: payload["external_transaction_id"],
        local_member_email: payload["local_member_email"],
        local_member_uid: payload["local_member_uid"],
        local_organization_id: payload["local_organization_id"],
        remote_user_identifier: payload["remote_user_identifier"],
        amount: amount,
        reason: payload["reason"]
      )
    end

    def initialize(partner:)
      @partner = partner
    end

    # Process an inbound transfer (remote → local)
    def process_inbound(external_transaction_id:, local_member_email: nil,
                        local_member_uid: nil, local_organization_id:,
                        remote_user_identifier:, amount:, reason: nil)
      validate_partner_can_transact!

      org = Organization.find(local_organization_id)
      member = find_local_member(org, email: local_member_email, member_uid: local_member_uid)

      ActiveRecord::Base.transaction do
        fed_txn = FederationTransaction.create!(
          federation_partner: @partner,
          external_transaction_id: external_transaction_id,
          direction: "inbound",
          local_account_id: member.account.id,
          remote_user_identifier: remote_user_identifier,
          amount: amount,
          reason: reason
        )

        # Credit local member from org's federation pool
        transfer = Transfer.new
        transfer.source = org.account.id
        transfer.destination = member.account.id
        transfer.amount = amount
        transfer.reason = "[Federation] #{reason}"
        transfer.save!

        fed_txn.complete!(local_transfer: transfer)

        # Notify partner of completion
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
    end

    # Initiate an outbound transfer (local → remote)
    def initiate_outbound(local_account:, remote_user_identifier:, amount:, reason: nil)
      validate_partner_can_transact!

      org = local_account.organization

      ActiveRecord::Base.transaction do
        fed_txn = FederationTransaction.create!(
          federation_partner: @partner,
          direction: "outbound",
          local_account_id: local_account.id,
          remote_user_identifier: remote_user_identifier,
          amount: amount,
          reason: reason
        )

        # Debit local member to org's federation pool
        transfer = Transfer.new
        transfer.source = local_account.id
        transfer.destination = org.account.id
        transfer.amount = amount
        transfer.reason = "[Federation] #{reason}"
        transfer.save!

        fed_txn.complete!(local_transfer: transfer)

        # Request remote partner to credit the remote user
        WebhookSender.send_async(
          partner: @partner,
          event: "transaction.requested",
          payload: {
            external_transaction_id: fed_txn.id.to_s,
            remote_user_identifier: remote_user_identifier,
            amount: amount,
            reason: reason,
            source_platform: "timeoverflow",
            source_organization_id: org.id,
            source_organization_name: org.name
          }
        )

        fed_txn
      end
    end

    private

    def validate_partner_can_transact!
      raise "Partner cannot transact" unless @partner.can_transact?
    end

    def find_local_member(org, email: nil, member_uid: nil)
      member = if member_uid.present?
                 org.members.active.find_by!(member_uid: member_uid)
               elsif email.present?
                 user = User.find_by!(email: email)
                 org.members.active.find_by!(user: user)
               else
                 raise "Must provide local_member_email or local_member_uid"
               end

      raise "Member account not found" unless member.account
      member
    end
  end
end

# Federation API: Cross-platform time transfer endpoint.
#
# Handles inbound transfer requests from federation partners.
# Uses a two-phase protocol:
#   1. Partner sends POST /api/v1/transfers (creates pending federation_transaction)
#   2. This controller validates, creates the local Transfer + Movements
#   3. Marks the federation_transaction as completed
#   4. Sends confirmation webhook back to the partner
#
# For outbound transfers (local user → remote user), the Federation::TransferHandler
# service is used instead.
#
module Api
  module V1
    class TransfersController < BaseController
      before_action -> { require_permission!(:transactions) }

      # POST /api/v1/transfers
      #
      # Params:
      #   partner_id: ID of the federation partner
      #   external_transaction_id: partner's transaction reference
      #   direction: "inbound" (remote sends to local) or "outbound" (local sends to remote)
      #   local_account_id: the local Account ID involved
      #   remote_user_identifier: identifier of the remote user (email or external ID)
      #   amount: time amount in seconds
      #   reason: description of the transfer
      #
      def create
        partner = FederationPartner.active.find(params[:partner_id])

        unless partner.can_transact?
          return respond_with_error("Partner is not enabled for transactions", status: :forbidden)
        end

        fed_txn = nil
        local_transfer = nil

        ActiveRecord::Base.transaction do
          fed_txn = FederationTransaction.create!(
            federation_partner: partner,
            external_transaction_id: params[:external_transaction_id],
            direction: params[:direction] || "inbound",
            local_account_id: params[:local_account_id],
            remote_user_identifier: params[:remote_user_identifier],
            amount: params[:amount].to_i,
            reason: params[:reason],
            metadata: {
              "initiated_by" => "federation_api",
              "api_key_name" => @current_api_key.name
            }
          )

          local_account = Account.find(params[:local_account_id])

          if fed_txn.direction == "inbound"
            # Remote user sends time to local member
            # Credit the local account from the organization's federation account
            org = local_account.organization
            source_account = org.account
            local_transfer = create_local_transfer(
              source: source_account,
              destination: local_account,
              amount: fed_txn.amount,
              reason: fed_txn.reason
            )
          else
            # Local member sends time to remote user
            # Debit the local account to the organization's federation account
            org = local_account.organization
            destination_account = org.account
            local_transfer = create_local_transfer(
              source: local_account,
              destination: destination_account,
              amount: fed_txn.amount,
              reason: fed_txn.reason
            )
          end

          fed_txn.complete!(local_transfer: local_transfer)
        end

        # Send confirmation webhook asynchronously
        Federation::WebhookSender.send_async(
          partner: partner,
          event: "transaction.completed",
          payload: {
            external_transaction_id: fed_txn.external_transaction_id,
            federation_transaction_id: fed_txn.id,
            local_transfer_id: local_transfer.id,
            status: "completed",
            completed_at: fed_txn.completed_at.iso8601
          }
        )

        respond_with_data(
          {
            federation_transaction_id: fed_txn.id,
            external_transaction_id: fed_txn.external_transaction_id,
            local_transfer_id: local_transfer.id,
            status: fed_txn.status,
            amount: fed_txn.amount,
            direction: fed_txn.direction,
            completed_at: fed_txn.completed_at&.iso8601
          },
          status: :created
        )

      rescue ActiveRecord::RecordInvalid => e
        respond_with_error("Transfer failed: #{e.message}", status: :unprocessable_entity)
      rescue => e
        # Cancel the federation transaction if it was created
        fed_txn&.cancel!(reason: e.message) if fed_txn&.pending?
        respond_with_error("Transfer failed: #{e.message}", status: :internal_server_error)
      end

      private

      def create_local_transfer(source:, destination:, amount:, reason:)
        transfer = Transfer.new
        transfer.source = source.id
        transfer.destination = destination.id
        transfer.amount = amount
        transfer.reason = "[Federation] #{reason}"
        transfer.save!
        transfer
      end
    end
  end
end

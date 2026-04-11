# POST /federation/transfers
#
# Allows a logged-in member to initiate a cross-platform time transfer
# to a remote user on a federation partner platform.
#
module FederationUi
  class TransfersController < BaseController
    before_action :require_active_member!

    # POST /federation/transfers
    def create
      partner = FederationPartner.active.find(params[:partner_id])

      unless partner.can_transact?
        return respond_with_error("Partner is not enabled for transactions", status: :forbidden)
      end

      unless Federation::AccessControl.member_can_send?(current_member, partner: partner)
        return respond_with_error("You have not opted in to federation transfers", status: :forbidden)
      end

      amount_seconds = if params[:amount_hours].present?
        (params[:amount_hours].to_f * 3600).to_i
      else
        params[:amount].to_i
      end

      # Validate amount limits (matches API endpoint behaviour)
      if amount_seconds <= 0
        return respond_with_error("Amount must be positive", status: :unprocessable_entity)
      end
      max_amount = Rails.application.config.federation.max_transfer_amount
      max_amount = 360_000 if max_amount <= 0
      if amount_seconds > max_amount
        return respond_with_error("Amount exceeds maximum (#{max_amount} seconds / #{(max_amount / 3600.0).round(1)} hours)", status: :unprocessable_entity)
      end

      handler = Federation::TransferHandler.new(partner: partner)
      fed_txn = handler.initiate_outbound(
        local_account: current_member.account,
        remote_user_identifier: params[:recipient_id] || params[:remote_user_identifier],
        amount: amount_seconds,
        reason: params[:reason] || params[:description]
      )

      # Notify the member about the sent transfer
      Federation::NotificationService.notify(
        member: current_member,
        event_type: :transfer_sent,
        data: {
          amount: amount_seconds,
          remote_user_identifier: params[:recipient_id] || params[:remote_user_identifier],
          reason: params[:reason] || params[:description],
          partner_name: partner.name
        }
      )

      respond_with_data({
        federation_transaction_id: fed_txn.id,
        status: fed_txn.status,
        amount_seconds: amount_seconds,
        amount_hours: (amount_seconds / 3600.0).round(2)
      }, status: :created)

    rescue ArgumentError => e
      respond_with_error(e.message, status: :unprocessable_entity)
    rescue ActiveRecord::RecordInvalid => e
      respond_with_error(e.record.errors.full_messages.join(", "), status: :unprocessable_entity)
    end
  end
end

# Federation API: Account balance endpoints.
#
# Allows federation partners to check member account balances
# and recent movement history.
#
module Api
  module V1
    class AccountsController < BaseController
      before_action -> { require_permission!(:transactions) }

      # GET /api/v1/accounts/:id
      def show
        account = Account.find(params[:id])
        movements = account.movements.order(created_at: :desc).limit(params[:limit] || 20)

        respond_with_data(
          id: account.id,
          accountable_type: account.accountable_type,
          accountable_id: account.accountable_id,
          organization_id: account.organization_id,
          balance: account.balance,
          flagged: account.flagged,
          max_allowed_balance: account.max_allowed_balance,
          min_allowed_balance: account.min_allowed_balance,
          recent_movements: movements.map { |m| serialize_movement(m) }
        )
      end

      private

      def serialize_movement(movement)
        {
          id: movement.id,
          amount: movement.amount,
          transfer_id: movement.transfer_id,
          created_at: movement.created_at.iso8601
        }
      end
    end
  end
end

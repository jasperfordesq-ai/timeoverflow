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
        # H1: Scope account access properly for both key types.
        # Org-scoped keys: only accounts belonging to that org.
        # Global keys: scope to the organization_id param (if given) or
        #   any org account — but must belong to an org (no dangling accounts).
        account = find_scoped_account!

        # Enforce org-level federation setting.
        if account.organization && !Federation::AccessControl.org_enabled?(account.organization)
          return respond_with_error("Federation is not enabled for this organization", status: :forbidden)
        end

        # H2: Paginate movements rather than using an unbounded limit param.
        page     = [(params[:page] || 1).to_i, 1].max
        per_page = [[(params[:per_page] || 20).to_i, 1].max, 100].min
        total_movements = account.movements.count
        movements = account.movements
                      .order(created_at: :desc)
                      .limit(per_page)
                      .offset((page - 1) * per_page)

        movements_meta = {
          current_page: page,
          per_page: per_page,
          total_count: total_movements,
          total_pages: total_movements.zero? ? 0 : (total_movements.to_f / per_page).ceil
        }

        respond_with_data({
          id: account.id,
          accountable_type: account.accountable_type,
          accountable_id: account.accountable_id,
          organization_id: account.organization_id,
          balance: account.balance,
          flagged: account.flagged,
          max_allowed_balance: account.read_attribute(:max_allowed_balance),
          min_allowed_balance: account.read_attribute(:min_allowed_balance),
          movements: movements.map { |m| serialize_movement(m) },
          movements_meta: movements_meta
        })
      end

      private

      # H1: Enforce account-to-org scoping for both key types.
      def find_scoped_account!
        if @current_api_key.organization
          # Org-scoped key — strict: only this org's accounts
          @current_api_key.organization.all_accounts.find(params[:id])
        elsif params[:organization_id].present?
          # Global key with explicit org_id param — scope to that org
          org = Organization.find(params[:organization_id])
          org.all_accounts.find(params[:id])
        else
          # Global key, no org param — account must belong to some org
          account = Account.find(params[:id])
          unless account.organization.present?
            raise ActiveRecord::RecordNotFound, "Account #{params[:id]} has no associated organization"
          end
          account
        end
      end

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

module Api
  module V1
    class CreditCommonsController < BaseController
      # Most CC endpoints need auth but use the standard API key mechanism
      skip_before_action :authenticate_api_key!, only: [:about, :forms]
      skip_before_action :enforce_rate_limit!, only: [:about, :forms]

      def about
        org = current_organization || Organization.first
        unless org
          return render json: { errors: [{ class: "CCFailure", message: "No organizations configured" }] }, status: :service_unavailable
        end
        config = FederationCcNodeConfig.for(org)
        render json: config.build_about_response
      end

      def accounts
        require_organization!
        return if performed?

        config = FederationCcNodeConfig.for(current_organization)
        members = current_organization.members.active.includes(:user, :account)

        # Apply consent filter — only show discoverable members (same as REST API)
        discoverable_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        members = members.where(id: discoverable_ids)

        accounts = members.map do |m|
          {
            id: "#{config.node_slug}/#{m.member_uid || m.id}",
            balance: m.account&.balance.to_i / 3600.0,
            name: m.user&.username
          }
        end

        render json: { data: accounts, meta: { number_of_results: accounts.size } }
      end

      def account
        require_organization!
        return if performed?

        username = params[:acc_id].to_s.split("/").last
        member = current_organization.members.active.find_by(member_uid: username) ||
                 current_organization.members.active.find_by(id: username)

        return render(json: { errors: [{ class: "CCViolation", message: "Account not found" }] }, status: :not_found) unless member
        return render(json: { errors: [{ class: "CCViolation", message: "Account has no balance record" }] }, status: :not_found) unless member.account

        balance = member.account.balance.to_i / 3600.0
        completed = FederationTransaction.completed.where(local_account_id: member.account.id)

        render json: {
          balance: balance,
          volume: completed.sum(:amount) / 3600.0,
          gross_in: completed.inbound.sum(:amount) / 3600.0,
          gross_out: completed.outbound.sum(:amount) / 3600.0,
          trades: completed.count,
          partners: completed.select(:remote_user_identifier).distinct.count
        }
      end

      def create_transaction
        # Delegate to existing transfer handler, with CC format translation
        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: nil)
        # Parse CC transaction format into canonical TO format
        payload = adapter.parse_cc_transaction(params)

        respond_with_data({ status: "accepted", message: "Transaction support via CC protocol is in development" }, status: :accepted)
      end

      def show_transaction
        # Scope by organization to prevent cross-partner transaction leaks
        scope = current_organization ? FederationTransaction.where(organization_id: current_organization.id) : FederationTransaction
        txn = scope.find_by(external_transaction_id: params[:uuid])
        return render(json: { errors: [{ class: "CCViolation", message: "Transaction not found" }] }, status: :not_found) unless txn

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: txn.federation_partner)
        render json: adapter.to_cc_transaction(txn)
      end

      def transition_transaction
        respond_with_data({ status: "acknowledged", message: "State transitions via CC protocol are in development" }, status: :accepted)
      end

      def relay
        respond_with_data({ status: "acknowledged", message: "Multi-hop relay via CC protocol is in development" }, status: :accepted)
      end

      def entries
        require_organization!
        return if performed?

        transactions = FederationTransaction.completed
          .where(organization_id: current_organization.id)
          .includes(transfer: :movements)
          .order(created_at: :desc)
          .limit(params[:limit]&.to_i || 25)

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: nil)
        entries = transactions.flat_map { |txn| adapter.generate_entries(txn) }

        render json: { data: entries, meta: { number_of_results: entries.size } }
      end

      def transaction_entries
        txn = FederationTransaction.find_by(external_transaction_id: params[:uuid])
        return render(json: { errors: [{ class: "CCViolation", message: "Transaction not found" }] }, status: :not_found) unless txn

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: txn.federation_partner)
        render json: { data: adapter.generate_entries(txn) }
      end

      def forms
        render json: {
          data: [
            { id: "default", workflow: "+|PPC-PE-CE=", label: "Standard Transfer" },
            { id: "instant", workflow: "+|PC-PE-CE=", label: "Instant Transfer (skip validation)" }
          ]
        }
      end
    end
  end
end

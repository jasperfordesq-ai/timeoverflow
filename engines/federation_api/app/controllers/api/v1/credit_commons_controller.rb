module Api
  module V1
    class CreditCommonsController < BaseController
      # Most CC endpoints need auth but use the standard API key mechanism
      skip_before_action :authenticate_api_key!, only: [:about, :forms]
      skip_before_action :enforce_rate_limit!, only: [:about, :forms]

      def about
        org = current_organization || Organization.first
        unless org
          return respond_with_error("No organizations configured", status: :service_unavailable)
        end
        config = FederationCcNodeConfig.for(org)
        respond_with_data(config.build_about_response)
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

        respond_with_data(accounts, meta: { number_of_results: accounts.size })
      end

      def account
        require_organization!
        return if performed?

        username = params[:acc_id].to_s.split("/").last
        member = current_organization.members.active.find_by(member_uid: username) ||
                 current_organization.members.active.find_by(id: username)

        return respond_with_error("Account not found", status: :not_found) unless member
        return respond_with_error("Account has no balance record", status: :not_found) unless member.account

        balance = member.account.balance.to_i / 3600.0
        completed = FederationTransaction.completed.where(local_account_id: member.account.id)

        respond_with_data({
          balance: balance,
          volume: completed.sum(:amount) / 3600.0,
          gross_in: completed.inbound.sum(:amount) / 3600.0,
          gross_out: completed.outbound.sum(:amount) / 3600.0,
          trades: completed.count,
          partners: completed.select(:remote_user_identifier).distinct.count
        })
      end

      def create_transaction
        respond_with_error("Transaction creation via CC protocol is not yet implemented", status: :not_implemented)
      end

      def show_transaction
        # Scope by organization to prevent cross-partner transaction leaks
        scope = current_organization ? FederationTransaction.where(organization_id: current_organization.id) : FederationTransaction
        txn = scope.find_by(external_transaction_id: params[:uuid])
        return respond_with_error("Transaction not found", status: :not_found) unless txn

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: txn.federation_partner)
        respond_with_data(adapter.to_cc_transaction(txn))
      end

      def transition_transaction
        respond_with_error("State transitions via CC protocol are not yet implemented", status: :not_implemented)
      end

      def relay
        respond_with_error("Multi-hop relay via CC protocol is not yet implemented", status: :not_implemented)
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

        respond_with_data(entries, meta: { number_of_results: entries.size })
      end

      def transaction_entries
        txn = FederationTransaction.find_by(external_transaction_id: params[:uuid])
        return respond_with_error("Transaction not found", status: :not_found) unless txn

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: txn.federation_partner)
        respond_with_data(adapter.generate_entries(txn))
      end

      def forms
        respond_with_data([
          { id: "default", workflow: "+|PPC-PE-CE=", label: "Standard Transfer" },
          { id: "instant", workflow: "+|PC-PE-CE=", label: "Instant Transfer (skip validation)" }
        ])
      end
    end
  end
end

module Api
  module V1
    class CreditCommonsController < BaseController
      # Most CC endpoints need auth but use the standard API key mechanism
      skip_before_action :authenticate_api_key!, only: [:about, :forms]
      skip_before_action :enforce_rate_limit!, only: [:about, :forms]
      before_action -> { require_permission!(:transactions) }, only: [:show_transaction, :transaction_entries, :accounts, :account, :entries]
      before_action :require_json_content_type!, only: [:create_transaction, :transition_transaction]

      def about
        org = current_organization || (params[:organization_id].present? ? Organization.find_by(id: params[:organization_id]) : nil)
        unless org
          return respond_with_error(I18n.t("federation_api.errors.cc_no_organizations", default: "No organizations configured"), status: :service_unavailable)
        end
        config = FederationCcNodeConfig.for(org)
        if @current_api_key.present?
          respond_with_data(config.build_about_response)
        else
          response = config.build_about_response
          response.delete(:accounts)
          response.delete(:traders)
          response.delete(:trades)
          response.delete(:volume)
          response.delete(:validated_window)
          respond_with_data(response)
        end
      end

      def accounts
        require_organization!
        return if performed?

        config = FederationCcNodeConfig.for(current_organization)
        members = current_organization.members.active.includes(:user, :account)

        # Apply consent filter — only show discoverable members (same as REST API)
        discoverable_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        members = members.where(id: discoverable_ids)

        # Paginate to prevent unbounded result sets.
        page_size = [[(params[:limit]&.to_i || 100), 1].max, 500].min
        offset = [(params[:offset]&.to_i || 0), 0].max
        total = members.count
        members = members.offset(offset).limit(page_size)

        accounts = members.map do |m|
          {
            id: "#{config.node_slug}/#{m.member_uid || m.id}",
            balance: m.account&.balance.to_i / 3600.0,
            name: m.user&.username
          }
        end

        respond_with_data(accounts, meta: { number_of_results: accounts.size, total: total })
      end

      def account
        require_organization!
        return if performed?

        username = params[:acc_id].to_s.split("/").last
        member = current_organization.members.active.find_by(member_uid: username) ||
                 current_organization.members.active.find_by(id: username)

        return respond_with_error(I18n.t("federation_api.errors.cc_account_not_found", default: "Account not found"), status: :not_found) unless member

        # Enforce discoverability: only show accounts for members who have opted in
        discoverable_ids = Federation::AccessControl.discoverable_member_ids(current_organization)
        unless discoverable_ids.include?(member.id)
          return respond_with_error(I18n.t("federation_api.errors.not_found", default: "Not found"), status: :not_found)
        end

        return respond_with_error(I18n.t("federation_api.errors.cc_no_balance", default: "Account has no balance record"), status: :not_found) unless member.account

        balance = member.account.balance.to_i / 3600.0
        completed = FederationTransaction.completed.where(local_account_id: member.account.id)

        # Aggregate stats in a single query instead of 5 separate ones.
        stats = completed.pick(
          Arel.sql("COALESCE(SUM(amount), 0)"),
          Arel.sql("COALESCE(SUM(CASE WHEN direction = 'inbound' THEN amount ELSE 0 END), 0)"),
          Arel.sql("COALESCE(SUM(CASE WHEN direction = 'outbound' THEN amount ELSE 0 END), 0)"),
          Arel.sql("COUNT(*)"),
          Arel.sql("COUNT(DISTINCT remote_user_identifier)")
        ) || [0, 0, 0, 0, 0]

        respond_with_data({
          balance: balance,
          volume: stats[0].to_f / 3600.0,
          gross_in: stats[1].to_f / 3600.0,
          gross_out: stats[2].to_f / 3600.0,
          trades: stats[3],
          partners: stats[4]
        })
      end

      def create_transaction
        respond_with_error(I18n.t("federation_api.errors.cc_not_implemented", default: "Transaction creation via CC protocol is not yet implemented"), status: :not_implemented)
      end

      def show_transaction
        # Scope by organization to prevent cross-partner transaction leaks
        scope = current_organization ? FederationTransaction.where(organization_id: current_organization.id) : FederationTransaction
        txn = scope.find_by(external_transaction_id: params[:uuid])
        return respond_with_error(I18n.t("federation_api.errors.transaction_not_found", default: "Transaction not found"), status: :not_found) unless txn

        # Enforce org access for global API keys
        if current_organization.nil? && txn.organization_id.present? && !@current_api_key.can_access_organization?(txn.organization_id)
          return respond_with_error(I18n.t("federation_api.errors.transaction_not_found", default: "Transaction not found"), status: :not_found)
        end

        # Verify the transaction's organization has federation enabled
        if txn.organization_id
          org = Organization.find_by(id: txn.organization_id)
          unless org && Federation::AccessControl.org_enabled?(org)
            return respond_with_error(I18n.t("federation_api.errors.not_found", default: "Not found"), status: :not_found)
          end
        end

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: txn.federation_partner)
        respond_with_data(adapter.to_cc_transaction(txn))
      end

      def transition_transaction
        respond_with_error(I18n.t("federation_api.errors.cc_transitions_not_implemented", default: "State transitions via CC protocol are not yet implemented"), status: :not_implemented)
      end

      def relay
        respond_with_error(I18n.t("federation_api.errors.cc_relay_not_implemented", default: "Multi-hop relay via CC protocol is not yet implemented"), status: :not_implemented)
      end

      def entries
        require_organization!
        return if performed?

        transactions = FederationTransaction.completed
          .where(organization_id: current_organization.id)
          .includes(transfer: :movements)
          .order(created_at: :desc)
          .limit([[(params[:limit]&.to_i || 25), 1].max, 100].min)

        adapter = Federation::Adapters::CreditCommonsAdapter.new(partner: nil)
        entries = transactions.flat_map { |txn| adapter.generate_entries(txn) }

        respond_with_data(entries, meta: { number_of_results: entries.size })
      end

      def transaction_entries
        scope = current_organization ? FederationTransaction.where(organization_id: current_organization.id) : FederationTransaction
        txn = scope.find_by(external_transaction_id: params[:uuid])
        return respond_with_error(I18n.t("federation_api.errors.transaction_not_found", default: "Transaction not found"), status: :not_found) unless txn

        # Enforce org access for global API keys
        if current_organization.nil? && txn.organization_id.present? && !@current_api_key.can_access_organization?(txn.organization_id)
          return respond_with_error(I18n.t("federation_api.errors.transaction_not_found", default: "Transaction not found"), status: :not_found)
        end

        # Verify the transaction's organization has federation enabled
        if txn.organization_id
          org = Organization.find_by(id: txn.organization_id)
          unless org && Federation::AccessControl.org_enabled?(org)
            return respond_with_error(I18n.t("federation_api.errors.not_found", default: "Not found"), status: :not_found)
          end
        end

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

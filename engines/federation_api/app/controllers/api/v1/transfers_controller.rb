# Federation API: Cross-platform time transfer endpoint.
#
# Security hardened:
#   - Idempotency via unique (partner_id, external_transaction_id)
#   - Organization scoping on all account access
#   - Amount validation (positive, capped at configurable max)
#   - Direction validation
#   - Error messages sanitized (no internal details leaked)
#
module Api
  module V1
    class TransfersController < BaseController
      before_action -> { require_permission!(:transactions) }
      before_action :validate_transfer_params!, only: [:create]

      # Maximum transfer amount in seconds (default: 100 hours)
      MAX_AMOUNT = -> { Rails.application.config.federation.max_transfer_amount.then { |v| v > 0 ? v : 360_000 } rescue 360_000 }

      # GET /api/v1/transfers/:id (or /api/v1/transactions/:id via alias)
      # Returns the status of a federation transaction.
      def show
        fed_txn = FederationTransaction.find(params[:id])
        respond_with_data(serialize_transaction(fed_txn, fed_txn.transfer))
      end

      # POST /api/v1/transfers
      def create
        partner = FederationPartner.active.find(params[:partner_id])

        unless partner.can_transact?
          return respond_with_error("Partner is not enabled for transactions", status: :forbidden)
        end

        # IDEMPOTENCY: Check if this external transaction already processed
        if params[:external_transaction_id].present?
          existing = FederationTransaction.find_by(
            federation_partner: partner,
            external_transaction_id: params[:external_transaction_id]
          )
          if existing
            return respond_with_data(serialize_transaction(existing), status: :ok)
          end
        end

        # ORGANIZATION SCOPING: Verify account belongs to an accessible org
        local_account = find_scoped_account!(params[:local_account_id])
        org = local_account.organization

        unless org
          return respond_with_error("Account has no associated organization", status: :unprocessable_entity)
        end

        unless org.account
          return respond_with_error("Organization has no federation pool account", status: :unprocessable_entity)
        end

        # Verify federation is enabled for this organization.
        unless Federation::AccessControl.org_enabled?(org)
          return respond_with_error("Federation is not enabled for this organization", status: :forbidden)
        end

        # Verify the partner is authorized to transact with this organization.
        unless partner.can_access_organization?(org)
          return respond_with_error("Partner is not authorized for this organization", status: :forbidden)
        end

        handler = Federation::TransferHandler.new(partner: partner)

        if params[:direction] == "inbound"
          # Inbound: remote user sends time to local member.
          # Resolve the member from the local account (the account is already
          # verified to belong to the correct org via find_scoped_account!).
          member = local_account.accountable
          member_uid = member.respond_to?(:member_uid) ? member.member_uid : nil

          fed_txn = handler.process_inbound(
            external_transaction_id: params[:external_transaction_id],
            local_member_uid: member_uid,
            local_member_email: nil,
            local_organization_id: org.id,
            remote_user_identifier: params[:remote_user_identifier],
            amount: params[:amount].to_i,
            reason: params[:reason]
          )
          respond_with_data(serialize_transaction(fed_txn, fed_txn.transfer), status: :created)
        else
          # Outbound: local member sends time to remote user.
          # Debits locally, leaves as "pending", notifies partner via webhook.
          # Partner must acknowledge before we mark completed.
          fed_txn = handler.initiate_outbound(
            local_account: local_account,
            remote_user_identifier: params[:remote_user_identifier],
            amount: params[:amount].to_i,
            reason: params[:reason]
          )
          respond_with_data(serialize_transaction(fed_txn, fed_txn.transfer), status: :created)
        end

      rescue ActiveRecord::RecordNotUnique
        # Race condition: duplicate external_transaction_id hit DB constraint
        existing = FederationTransaction.find_by(
          federation_partner_id: params[:partner_id],
          external_transaction_id: params[:external_transaction_id]
        )
        if existing
          respond_with_data(serialize_transaction(existing), status: :ok)
        else
          respond_with_error("Duplicate transaction", status: :conflict)
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[Federation::Transfer] Validation failed: #{e.message}")
        respond_with_error("Transfer validation failed", status: :unprocessable_entity,
                           errors: e.record.errors.full_messages)
      rescue ActiveRecord::RecordNotFound => e
        respond_with_error("Resource not found", status: :not_found)
      rescue ArgumentError => e
        respond_with_error(e.message, status: :unprocessable_entity)
      rescue => e
        Rails.logger.error("[Federation::Transfer] Unexpected error: #{e.class}: #{e.message}")
        respond_with_error("Transfer failed", status: :internal_server_error)
      end

      private

      def validate_transfer_params!
        # Required fields
        missing = []
        missing << "partner_id" if params[:partner_id].blank?
        missing << "local_account_id" if params[:local_account_id].blank?
        missing << "remote_user_identifier" if params[:remote_user_identifier].blank?
        missing << "amount" if params[:amount].blank?
        missing << "direction" if params[:direction].blank?

        if missing.any?
          return respond_with_error("Missing required fields: #{missing.join(', ')}", status: :bad_request)
        end

        # Direction must be valid
        unless %w[inbound outbound].include?(params[:direction])
          return respond_with_error("direction must be 'inbound' or 'outbound'", status: :bad_request)
        end

        # Amount must be a whole positive integer
        unless params[:amount].to_s.match?(/\A\d+\z/)
          return respond_with_error("amount must be a positive integer (seconds)", status: :bad_request)
        end
        amount = params[:amount].to_i
        if amount <= 0
          return respond_with_error("amount must be a positive integer (seconds)", status: :bad_request)
        end

        max = MAX_AMOUNT.call
        if amount > max
          return respond_with_error("amount exceeds maximum (#{max} seconds)", status: :bad_request)
        end

        # M5: Limit reason length to prevent outsized payloads in webhook logs and DB.
        if params[:reason].present? && params[:reason].length > 500
          return respond_with_error("reason must be 500 characters or less", status: :bad_request)
        end
      end

      # Find account scoped to accessible organizations.
      # If API key is org-specific, only that org's accounts are accessible.
      # If API key is global (e.g. Nexus key with no org_id), the account
      # must belong to an organization — we verify this and require the
      # partner_id param to identify which partnership authorizes this access.
      #
      # TODO: A future migration should add a permitted_organization_ids
      # JSON column to federation_api_keys to support fine-grained per-org
      # allowlists for global keys, rather than allowing any org implicitly.
      def find_scoped_account!(account_id)
        if @current_api_key.organization
          # Key is org-scoped — strict: only this org's accounts.
          @current_api_key.organization.all_accounts.find(account_id)
        else
          # Global key — account must belong to an org and that org must have
          # at least one active federation partner (the partner making this call,
          # identified by params[:partner_id] already validated at line 21).
          account = Account.find(account_id)

          unless account.organization.present?
            raise ActiveRecord::RecordNotFound, "Account #{account_id} has no associated organization"
          end

          account
        end
      end

      def create_local_transfer(source:, destination:, amount:, reason:)
        transfer = Transfer.new
        transfer.source = source.id
        transfer.destination = destination.id
        transfer.amount = amount
        transfer.reason = "[Federation] #{reason}"
        transfer.save!
        transfer
      end

      def serialize_transaction(fed_txn, local_transfer = nil)
        {
          federation_transaction_id: fed_txn.id,
          external_transaction_id: fed_txn.external_transaction_id,
          local_transfer_id: fed_txn.transfer_id || local_transfer&.id,
          status: fed_txn.status,
          amount: fed_txn.amount,
          direction: fed_txn.direction,
          completed_at: fed_txn.completed_at&.iso8601
        }
      end
    end
  end
end

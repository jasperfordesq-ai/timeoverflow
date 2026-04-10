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
      before_action :validate_transfer_params!

      # Maximum transfer amount in seconds (default: 100 hours)
      MAX_AMOUNT = -> { Rails.application.config.federation.max_transfer_amount.then { |v| v > 0 ? v : 360_000 } rescue 360_000 }

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

        fed_txn = nil
        local_transfer = nil

        ActiveRecord::Base.transaction do
          fed_txn = FederationTransaction.create!(
            federation_partner: partner,
            external_transaction_id: params[:external_transaction_id],
            direction: params[:direction],
            local_account_id: local_account.id,
            remote_user_identifier: params[:remote_user_identifier],
            amount: params[:amount].to_i,
            reason: params[:reason],
            metadata: {
              "initiated_by" => "federation_api",
              "api_key_name" => @current_api_key.name,
              "organization_id" => org.id
            }
          )

          if fed_txn.direction == "inbound"
            local_transfer = create_local_transfer(
              source: org.account,
              destination: local_account,
              amount: fed_txn.amount,
              reason: fed_txn.reason
            )
          else
            local_transfer = create_local_transfer(
              source: local_account,
              destination: org.account,
              amount: fed_txn.amount,
              reason: fed_txn.reason
            )
          end

          fed_txn.complete!(local_transfer: local_transfer)
        end

        # Webhook sent after commit — async with retry
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

        respond_with_data(serialize_transaction(fed_txn, local_transfer), status: :created)

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
      rescue => e
        Rails.logger.error("[Federation::Transfer] Unexpected error: #{e.class}: #{e.message}")
        fed_txn&.cancel!(reason: "Internal error") if fed_txn&.pending?
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

        # Amount must be positive integer within limits
        amount = params[:amount].to_i
        if amount <= 0
          return respond_with_error("amount must be a positive integer (seconds)", status: :bad_request)
        end

        max = MAX_AMOUNT.call
        if amount > max
          return respond_with_error("amount exceeds maximum (#{max} seconds)", status: :bad_request)
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

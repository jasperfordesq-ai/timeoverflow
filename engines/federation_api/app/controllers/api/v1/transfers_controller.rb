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
      before_action :normalize_nexus_params!, only: [:create]
      before_action :validate_transfer_params!, only: [:create]

      # Maximum transfer amount in seconds (default: 100 hours)
      MAX_AMOUNT = -> { Rails.application.config.federation.max_transfer_amount.then { |v| v > 0 ? v : 360_000 } rescue 360_000 }

      # GET /api/v1/transfers/:id (or /api/v1/transactions/:id via alias)
      # Returns the status of a federation transaction.
      def show
        fed_txn = find_scoped_transaction!(params[:id])
        respond_with_data(serialize_transaction(fed_txn, fed_txn.transfer))
      end

      # POST /api/v1/transfers
      def create
        partner = FederationPartner.active.find(params[:partner_id])

        unless partner.can_transact?
          return respond_with_error(I18n.t("federation_api.errors.partner_cannot_transact", default: "Partner is not enabled for transactions"), status: :forbidden)
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
          return respond_with_error(I18n.t("federation_api.errors.account_no_org", default: "Account has no associated organization"), status: :unprocessable_entity)
        end

        unless org.account
          return respond_with_error(I18n.t("federation_api.errors.org_no_pool_account", default: "Organization has no federation pool account"), status: :unprocessable_entity)
        end

        # Verify federation is enabled for this organization.
        unless Federation::AccessControl.org_enabled?(org)
          return respond_with_error(I18n.t("federation_api.errors.federation_disabled", default: "Federation is not enabled for this organization"), status: :forbidden)
        end

        # Verify the partner is authorized to transact with this organization.
        unless partner.can_access_organization?(org)
          return respond_with_error(I18n.t("federation_api.errors.partner_not_authorized", default: "Partner is not authorized for this organization"), status: :forbidden)
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
          respond_with_error(I18n.t("federation_api.errors.duplicate_transaction", default: "Duplicate transaction"), status: :conflict)
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("[Federation::Transfer] Validation failed: #{e.message}")
        respond_with_error(I18n.t("federation_api.errors.transfer_validation_failed", default: "Transfer validation failed"), status: :unprocessable_entity,
                           errors: e.record.errors.full_messages)
      rescue ActiveRecord::RecordNotFound => e
        respond_with_error(I18n.t("federation_api.errors.resource_not_found", default: "Resource not found"), status: :not_found)
      rescue ArgumentError => e
        Rails.logger.warn("[Federation::Transfer] ArgumentError: #{e.message}")
        respond_with_error(I18n.t("federation_api.errors.transfer_argument_error", default: "Invalid transfer parameters"), status: :unprocessable_entity)
      rescue => e
        Rails.logger.error("[Federation::Transfer] Unexpected error: #{e.class}: #{e.message}")
        respond_with_error(I18n.t("federation_api.errors.transfer_failed", default: "Transfer failed"), status: :internal_server_error)
      end

      private

      # Nexus payload compatibility layer.
      #
      # Nexus sends: { sender_id, recipient_id, amount (hours), description }
      # TO expects:  { partner_id, direction, local_account_id, remote_user_identifier, amount (seconds), reason }
      #
      # Detect the Nexus format (has recipient_id but no direction) and translate.
      def normalize_nexus_params!
        return unless params[:recipient_id].present? && params[:direction].blank?

        Rails.logger.info("[Federation::Transfer] Detected Nexus payload format, normalizing")

        # This is an inbound transfer from a Nexus user to a local TO member.
        # recipient_id = the local TO member (by ID or member_uid)
        # sender_id = the remote Nexus user identifier
        org = @current_api_key.organization
        recipient = nil

        if org
          recipient = org.members.active.find_by(id: params[:recipient_id]) ||
                      org.members.active.find_by(member_uid: params[:recipient_id])
        else
          # Global key: try to find the member across all orgs
          recipient = Member.find_by(id: params[:recipient_id], active: true)
        end

        unless recipient&.account
          return respond_with_error(I18n.t("federation_api.errors.recipient_not_found", default: "Could not resolve recipient member or account"), status: :unprocessable_entity)
        end

        # Infer partner from API key's org context, or single-partner shortcut.
        partner_id = params[:partner_id]
        if partner_id.blank?
          if @current_api_key&.organization
            partner = FederationPartner.active.for_organization(@current_api_key.organization.id).first
          else
            partners = FederationPartner.active
            partner = partners.first if partners.count == 1
          end
          partner_id = partner&.id
        end

        # Convert Nexus hours to TO seconds (use .to_f to handle fractional hours)
        nexus_amount = params[:amount].to_f
        amount_seconds = (nexus_amount * 3600).round

        # Rewrite params to TO native format
        params[:partner_id] = partner_id
        params[:direction] = "inbound"
        params[:local_account_id] = recipient.account.id
        params[:remote_user_identifier] = params[:sender_id] || "unknown_remote_user"
        params[:amount] = amount_seconds.to_s
        params[:reason] = params[:description] if params[:reason].blank?
        params[:external_transaction_id] ||= "nexus_#{Digest::SHA256.hexdigest("#{partner_id}:#{params[:sender_id]}:#{params[:recipient_id]}:#{params[:amount]}:#{params[:description]}")[0..31]}"
      end

      def validate_transfer_params!
        # Required fields
        missing = []
        missing << "partner_id" if params[:partner_id].blank?
        missing << "local_account_id" if params[:local_account_id].blank?
        missing << "remote_user_identifier" if params[:remote_user_identifier].blank?
        missing << "amount" if params[:amount].blank?
        missing << "direction" if params[:direction].blank?

        if missing.any?
          return respond_with_error(I18n.t("federation_api.errors.missing_fields", fields: missing.join(", "), default: "Missing required fields: %{fields}"), status: :bad_request)
        end

        # Direction must be valid
        unless %w[inbound outbound].include?(params[:direction])
          return respond_with_error(I18n.t("federation_api.errors.invalid_direction", default: "direction must be 'inbound' or 'outbound'"), status: :bad_request)
        end

        # Amount must be a whole positive integer
        unless params[:amount].to_s.match?(/\A\d+\z/)
          return respond_with_error(I18n.t("federation_api.errors.invalid_amount", default: "amount must be a positive integer (seconds)"), status: :bad_request)
        end
        amount = params[:amount].to_i
        if amount <= 0
          return respond_with_error(I18n.t("federation_api.errors.invalid_amount", default: "amount must be a positive integer (seconds)"), status: :bad_request)
        end

        max = MAX_AMOUNT.call
        if amount > max
          return respond_with_error(I18n.t("federation_api.errors.amount_exceeds_max", max: max, default: "amount exceeds maximum (%{max} seconds)"), status: :bad_request)
        end

        # M5: Limit reason length to prevent outsized payloads in webhook logs and DB.
        # Strip and sanitize the reason field.
        params[:reason] = params[:reason].to_s.strip if params[:reason].present?
        if params[:reason].present? && params[:reason].length > 500
          return respond_with_error(I18n.t("federation_api.errors.reason_too_long", max: 500, default: "reason must be %{max} characters or less"), status: :bad_request)
        end
      end

      # Find account scoped to accessible organizations.
      # If API key is org-specific, only that org's accounts are accessible.
      # If API key is global, check permitted_organization_ids for fine-grained
      # org allowlists. Keys with empty permitted_organization_ids allow any org.
      def find_scoped_account!(account_id)
        if @current_api_key.organization
          # Key is org-scoped — strict: only this org's accounts.
          @current_api_key.organization.all_accounts.find(account_id)
        else
          # Global key — account must belong to an org.
          account = Account.find(account_id)

          unless account.organization.present?
            raise ActiveRecord::RecordNotFound, "Account #{account_id} has no associated organization"
          end

          # Enforce permitted_organization_ids if configured on the key.
          unless @current_api_key.can_access_organization?(account.organization)
            raise ActiveRecord::RecordNotFound, "API key does not have access to organization #{account.organization.id}"
          end

          account
        end
      end

      # Scope transaction lookup by API key's organization access.
      def find_scoped_transaction!(id)
        if @current_api_key.organization
          FederationTransaction.where(organization_id: @current_api_key.organization_id).find(id)
        else
          txn = FederationTransaction.find(id)
          if txn.organization_id && !@current_api_key.can_access_organization?(txn.organization_id)
            raise ActiveRecord::RecordNotFound, "Transaction not found"
          end
          txn
        end
      end

      def serialize_transaction(fed_txn, local_transfer = nil)
        {
          federation_transaction_id: fed_txn.id,
          transaction_id: fed_txn.id,  # Nexus reads this field
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

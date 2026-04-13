# Cross-organization time transfers via the Federation Hub.
#
# For internal (same-instance) orgs: direct DB transfer, instant.
# For external partners: uses TransferHandler to debit locally + webhook to partner.
#
module FederationHub
  class TransfersController < BaseController
    def new
      @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)
      @external_partners = FederationPartner.active.where("feature_gates->>'transactions_enabled' = ?", "true").order(name: :asc)

      @selected_id = params[:org_id]
      @selected_type = params[:source_type] # "internal" or "external"
      @pre_selected_member_id = params[:member_id]
      @destination_members = []

      if @selected_id.present?
        if @selected_type == "external"
          partner = @external_partners.find_by(id: @selected_id)
          if partner
            @selected_name = partner.name
            @destination_members = fetch_external_members(partner)
          end
        else
          org = @internal_orgs.find_by(id: @selected_id)
          if org
            @selected_name = org.name
            @destination_members = Federation::InternalBrowser.members(org, viewer_organization: current_organization)
          end
        end
      end
    end

    def create
      dest_identifier = params[:destination_member_id].to_s.strip
      selected_id = params[:org_id].to_i
      source_type = params[:source_type]
      hours = params[:hours].to_i
      minutes = params[:minutes].to_i
      amount = (hours * 3600) + (minutes * 60)
      reason = params[:reason].to_s.strip

      # Reason length validation (matches API-level 500-char limit)
      if params[:reason].present? && params[:reason].to_s.length > 500
        flash[:alert] = t("federation_hub.transfers.reason_too_long", default: "Reason must be 500 characters or less")
        redirect_to new_federation_hub_transfer_path(org_id: selected_id, source_type: source_type) and return
      end

      # Validate amount — use same config as API controller for consistency
      max_amount = begin
        v = Rails.application.config.federation.max_transfer_amount
        v.to_i > 0 ? v.to_i : 360_000
      rescue NoMethodError, StandardError
        360_000
      end
      if amount <= 0
        flash[:alert] = t("federation_hub.transfers.invalid_amount")
        redirect_to new_federation_hub_transfer_path(org_id: selected_id, source_type: source_type)
        return
      end

      if amount > max_amount
        flash[:alert] = t("federation_hub.transfers.amount_too_large",
          max: "#{max_amount / 3600}h")
        redirect_to new_federation_hub_transfer_path(org_id: selected_id, source_type: source_type)
        return
      end

      source_account = current_member.account
      unless source_account
        flash[:alert] = t("federation_hub.transfers.no_source_account")
        redirect_to federation_hub_root_path
        return
      end

      # Balance validation for external transfers is now atomic inside
      # TransferHandler#initiate_outbound (lock! + check in the same transaction
      # as the debit). For internal transfers, we still do a quick pre-check
      # below but the real guard is the DB transaction in create_internal_transfer.
      if source_type != "external" && source_account.balance.to_i < amount
        flash[:alert] = t("federation_hub.transfers.exceeds_balance")
        redirect_to new_federation_hub_transfer_path(org_id: selected_id, source_type: source_type)
        return
      end

      if source_type == "external"
        partner = FederationPartner.active.find_by(id: selected_id)
        unless Federation::AccessControl.member_can_send?(current_member, partner: partner)
          flash[:alert] = t("federation_hub.transfers.sender_not_allowed")
          redirect_to new_federation_hub_transfer_path(org_id: selected_id, source_type: source_type)
          return
        end
        create_external_transfer(selected_id, dest_identifier, amount, reason, hours, minutes)
      else
        unless Federation::AccessControl.member_can_send?(current_member)
          flash[:alert] = t("federation_hub.transfers.sender_not_allowed")
          redirect_to new_federation_hub_transfer_path(org_id: selected_id, source_type: source_type)
          return
        end
        create_internal_transfer(selected_id, dest_identifier.to_i, amount, reason, hours, minutes)
      end
    end

    private

    def create_internal_transfer(org_id, dest_member_id, amount, reason, hours, minutes)
      target_org = Organization.find_by(id: org_id)
      unless target_org && Federation::InternalBrowser.can_browse?(current_organization, target_org)
        flash[:alert] = t("federation_hub.transfers.org_not_available")
        redirect_to new_federation_hub_transfer_path and return
      end

      dest_member = target_org.members.active.find_by(id: dest_member_id)
      unless dest_member
        flash[:alert] = t("federation_hub.transfers.member_not_found")
        redirect_to new_federation_hub_transfer_path(org_id: org_id) and return
      end

      dest_account = dest_member.account
      unless dest_account
        flash[:alert] = t("federation_hub.transfers.no_dest_account")
        redirect_to new_federation_hub_transfer_path(org_id: org_id) and return
      end

      unless Federation::AccessControl.member_can_receive?(dest_member)
        flash[:alert] = t("federation_hub.transfers.recipient_not_opted_in")
        redirect_to new_federation_hub_transfer_path(org_id: org_id) and return
      end

      transfer = Transfer.new(
        source: current_member.account,
        destination: dest_account,
        amount: amount,
        reason: reason.presence || t("federation_hub.transfers.default_reason",
          from_org: current_organization.name, to_org: target_org.name)
      )

      if transfer.save
        Rails.logger.info("[FederationHub::Transfer] Internal cross-org ##{transfer.id}: " \
          "#{current_organization.name} → #{target_org.name}, #{amount}s")

        flash[:notice] = t("federation_hub.transfers.success",
          amount: "#{hours}h #{minutes}m",
          recipient: dest_member.user&.username,
          org: target_org.name)
        redirect_to federation_hub_root_path and return
      else
        flash[:alert] = t("federation_hub.transfers.transfer_failed",
          default: "Transfer could not be completed. Please try again.")
        redirect_to new_federation_hub_transfer_path(org_id: org_id) and return
      end
    end

    def create_external_transfer(partner_id, remote_user_id, amount, reason, hours, minutes)
      partner = FederationPartner.active.find_by(id: partner_id)
      unless partner&.can_transact?
        flash[:alert] = t("federation_hub.transfers.org_not_available")
        redirect_to new_federation_hub_transfer_path
        return
      end

      handler = Federation::TransferHandler.new(partner: partner)
      fed_txn = handler.initiate_outbound(
        local_account: current_member.account,
        remote_user_identifier: remote_user_id,
        amount: amount,
        reason: reason.presence || t("federation_hub.transfers.default_reason",
          from_org: current_organization.name, to_org: partner.name)
      )

      flash[:notice] = t("federation_hub.transfers.external_success",
        amount: "#{hours}h #{minutes}m",
        partner: partner.name,
        default: "Transfer of #{hours}h #{minutes}m sent to #{partner.name}. It will be completed once the partner confirms.")
      redirect_to federation_hub_root_path
    rescue ArgumentError => e
      Rails.logger.warn("[FederationHub::Transfer] External transfer rejected: #{e.message}")
      # Surface balance / validation errors to the user (e.g. "Insufficient balance")
      flash[:alert] = e.message.include?("Insufficient balance") ? t("federation_hub.transfers.exceeds_balance") : e.message
      redirect_to new_federation_hub_transfer_path(org_id: partner_id, source_type: "external")
    rescue => e
      Rails.logger.error("[FederationHub::Transfer] External transfer failed: #{e.class}: #{e.message}")
      flash[:alert] = t("federation_hub.transfers.external_failed",
        default: "External transfer could not be completed. Please try again later.")
      redirect_to new_federation_hub_transfer_path(org_id: partner_id, source_type: "external")
    end

    def fetch_external_members(partner)
      client = Federation::PartnerApiClient.new(partner: partner)
      if partner.api_key_hash.present?
        result = client.send_event("members.list")
        if result["success"] != false
          data = result["data"] || result
          members = data.dig("result", "members") || data["members"] || []
          return members.is_a?(Array) ? members : []
        end
      end
      []
    rescue => e
      Rails.logger.warn("[FederationHub::Transfers] Failed to fetch members from #{partner.name}: #{e.message}")
      []
    end
  end
end

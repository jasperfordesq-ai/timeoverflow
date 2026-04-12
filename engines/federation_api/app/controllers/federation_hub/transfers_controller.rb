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

      # Validate amount
      max_amount = 360_000
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
        redirect_to new_federation_hub_transfer_path
        return
      end

      dest_member = target_org.members.active.find_by(id: dest_member_id)
      unless dest_member
        flash[:alert] = t("federation_hub.transfers.member_not_found")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
      end

      dest_account = dest_member.account
      unless dest_account
        flash[:alert] = t("federation_hub.transfers.no_dest_account")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
      end

      unless Federation::AccessControl.member_can_receive?(dest_member)
        flash[:alert] = t("federation_hub.transfers.recipient_not_opted_in")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
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
        redirect_to federation_hub_root_path
      else
        flash[:alert] = t("federation_hub.transfers.failed",
          error: transfer.errors.full_messages.join(", "))
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
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
    rescue => e
      Rails.logger.error("[FederationHub::Transfer] External transfer failed: #{e.class}: #{e.message}")
      flash[:alert] = t("federation_hub.transfers.failed", error: e.message)
      redirect_to new_federation_hub_transfer_path(org_id: partner_id, source_type: "external")
    end

    def fetch_external_members(partner)
      client = Federation::PartnerApiClient.new(partner: partner)
      if partner.api_key_hash.present?
        result = client.send(:post, "/receive", {
          event: "members.list",
          timestamp: Time.current.iso8601,
          platform: "timeoverflow",
          data: {}
        })
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

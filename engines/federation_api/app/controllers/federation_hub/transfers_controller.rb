# Cross-organization time transfers via the Federation Hub.
#
# Uses TimeOverflow's native Transfer model — which is already org-agnostic
# (it just moves time between Account IDs). The existing UI only shows
# same-org accounts; this controller enables cross-org transfers between
# members who have opted into federation.
#
# For internal (same-instance) orgs: direct DB transfer, instant.
# For external partners: delegates to the federation API (webhook/REST).
#
module FederationHub
  class TransfersController < BaseController
    def new
      @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)
      @external_partners = FederationPartner.active.order(name: :asc)

      @selected_org_id = params[:org_id]
      @pre_selected_member_id = params[:member_id]
      @destination_members = []

      if @selected_org_id.present?
        org = @internal_orgs.find_by(id: @selected_org_id)
        if org
          @selected_org_name = org.name
          @destination_members = Federation::InternalBrowser.members(org, viewer_organization: current_organization)
        end
      end
    end

    def create
      dest_member_id = params[:destination_member_id].to_i
      org_id = params[:org_id].to_i
      hours = params[:hours].to_i
      minutes = params[:minutes].to_i
      amount = (hours * 3600) + (minutes * 60)
      reason = params[:reason].to_s.strip

      # Validate amount
      max_amount = 360_000 # 100 hours in seconds
      if amount <= 0
        flash[:alert] = t("federation_hub.transfers.invalid_amount")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
      end

      if amount > max_amount
        flash[:alert] = t("federation_hub.transfers.amount_too_large",
          max: "#{max_amount / 3600}h", default: "Transfer amount exceeds the maximum of #{max_amount / 3600} hours.")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
      end

      # Find source account (current member's account)
      source_account = current_member.account
      unless source_account
        flash[:alert] = t("federation_hub.transfers.no_source_account")
        redirect_to federation_hub_root_path
        return
      end

      # Find destination — internal org member
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

      # Verify destination member has opted in to federation
      unless Federation::AccessControl.member_can_receive?(dest_member)
        flash[:alert] = t("federation_hub.transfers.recipient_not_opted_in")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
      end

      # Verify current member can send
      unless Federation::AccessControl.member_can_send?(current_member)
        flash[:alert] = t("federation_hub.transfers.sender_not_allowed")
        redirect_to new_federation_hub_transfer_path(org_id: org_id)
        return
      end

      # Create the transfer using TimeOverflow's native model
      transfer = Transfer.new(
        source: source_account,
        destination: dest_account,
        amount: amount,
        reason: reason.presence || t("federation_hub.transfers.default_reason",
          from_org: current_organization.name, to_org: target_org.name)
      )

      if transfer.save
        # The native Transfer + Movements already create a full audit trail.
        # Log a note in Rails logger for federation tracking.
        Rails.logger.info("[FederationHub::Transfer] Cross-org transfer ##{transfer.id}: " \
          "#{current_organization.name} → #{target_org.name}, #{amount}s, " \
          "member #{current_member.id} → #{dest_member.id}")

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
  end
end

module FederationHub
  class MessagesController < BaseController
    def index
      @messages = FederationMessage.includes(:federation_partner).where(
        organization_id: current_organization.id,
        local_member_id: current_member.id
      ).order(created_at: :desc).limit(100)

      # Group into conversations by (partner_id + remote_user_identifier)
      @conversations = @messages.group_by { |m|
        [m.federation_partner_id, m.remote_user_identifier]
      }.map do |key, msgs|
        partner_id, remote_user = key
        latest = msgs.first
        unread = msgs.count { |m| m.inbound? && !m.read_at }
        {
          partner_id: partner_id,
          partner_name: latest.federation_partner&.name || "Unknown",
          remote_user: remote_user,
          remote_user_name: msgs.map { |m| m.metadata&.dig("sender_username") }.compact.first || remote_user,
          latest_message: latest,
          message_count: msgs.size,
          unread_count: unread,
          last_activity: latest.created_at
        }
      end.sort_by { |c| c[:last_activity] }.reverse
    end

    def show
      @message = FederationMessage.find_by!(
        id: params[:id],
        local_member_id: current_member.id
      )

      # Load full conversation thread with this user
      @thread = FederationMessage.where(
        organization_id: current_organization.id,
        local_member_id: current_member.id,
        federation_partner_id: @message.federation_partner_id,
        remote_user_identifier: @message.remote_user_identifier
      ).order(created_at: :asc)

      # Bulk-mark all unread inbound messages in this thread as read
      # (single UPDATE instead of N individual updates).
      @thread.where(direction: "inbound", read_at: nil)
             .update_all(status: "read", read_at: Time.current)
    end

    def new
      @external_partners = FederationPartner.active.order(name: :asc)
      @internal_orgs = Federation::InternalBrowser.browsable_organizations(current_organization)

      @selected_id = params[:partner_id]
      @selected_type = params[:source_type] # "internal" or "external"
      @pre_recipient = params[:recipient_id]
      @pre_recipient_name = params[:recipient_name]
      @recipient_members = []

      if @selected_id.present?
        if @selected_type == "internal"
          org = @internal_orgs.find_by(id: @selected_id)
          if org
            @selected_name = org.name
            @recipient_members = Federation::InternalBrowser.members(org, viewer_organization: current_organization)
          end
        else
          partner = @external_partners.find_by(id: @selected_id)
          if partner
            @selected_name = partner.name
            @recipient_members = fetch_partner_members(partner)
          end
        end
      end
    end

    def create
      partner_id = params[:partner_id]
      source_type = params[:source_type]

      # For external partners, use FederationPartner
      # For internal orgs, we need to find the partner or handle differently
      if source_type == "internal"
        # Internal messages — create a direct FederationMessage without external delivery
        # For now, internal messaging uses the same path but without a partner
        flash[:alert] = t("federation_hub.messages.internal_not_yet",
          default: "Internal messaging between TimeOverflow communities is coming soon. Use the Members page to send time credits instead.")
        redirect_to new_federation_hub_message_path
        return
      end

      partner = FederationPartner.active.find(partner_id)

      handler = Federation::MessageHandler.new(partner: partner)
      @message = handler.send_outbound(
        member: current_member,
        remote_user_identifier: params[:recipient_id],
        subject: params[:subject],
        body: params[:body],
        organization: current_organization
      )

      if params[:reply_to].present?
        redirect_to federation_hub_message_path(params[:reply_to]), notice: t("federation_hub.messages.sent")
      else
        redirect_to federation_hub_messages_path, notice: t("federation_hub.messages.sent")
      end
    rescue ArgumentError => e
      redirect_to new_federation_hub_message_path(partner_id: partner_id, source_type: source_type), alert: e.message
    rescue => e
      redirect_to new_federation_hub_message_path(partner_id: partner_id, source_type: source_type),
        alert: t("federation_hub.messages.send_failed", error: e.message)
    end

    private

    def fetch_partner_members(partner)
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
      Rails.logger.warn("[FederationHub::Messages] Failed to fetch members from #{partner.name}: #{e.message}")
      []
    end
  end
end

module FederationHub
  class MessagesController < BaseController
    def index
      @messages = FederationMessage.where(
        organization_id: current_organization.id,
        local_member_id: current_member.id
      ).order(created_at: :desc).limit(100)

      # Group into conversations by (partner_id + remote_user_identifier)
      @conversations = @messages.group_by { |m|
        [m.federation_partner_id, m.remote_user_identifier]
      }.map do |key, msgs|
        partner_id, remote_user = key
        latest = msgs.first # already sorted desc
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

      # Mark all unread inbound messages in this thread as read
      @thread.each { |m| m.mark_read! if m.inbound? && !m.read_at }
    end

    def new
      @partners = FederationPartner.active.order(name: :asc)
      @pre_partner_id = params[:partner_id]
      @pre_recipient = params[:recipient_id]
      @pre_recipient_name = params[:recipient_name]
    end

    def create
      partner = FederationPartner.active.find(params[:partner_id])

      handler = Federation::MessageHandler.new(partner: partner)
      @message = handler.send_outbound(
        member: current_member,
        remote_user_identifier: params[:recipient_id],
        subject: params[:subject],
        body: params[:body],
        organization: current_organization
      )

      if params[:reply_to].present?
        # Redirect back to the conversation thread
        redirect_to federation_hub_message_path(params[:reply_to]), notice: t("federation_hub.messages.sent")
      else
        redirect_to federation_hub_messages_path, notice: t("federation_hub.messages.sent")
      end
    rescue ArgumentError => e
      redirect_to new_federation_hub_message_path, alert: e.message
    rescue => e
      redirect_to new_federation_hub_message_path, alert: t("federation_hub.messages.send_failed", error: e.message)
    end
  end
end

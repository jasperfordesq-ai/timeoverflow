module FederationHub
  class MessagesController < BaseController
    def index
      @messages = FederationMessage.where(
        organization_id: current_organization.id,
        local_member_id: current_member.id
      ).order(created_at: :desc).limit(50)
    end

    def show
      @message = FederationMessage.find_by!(
        id: params[:id],
        local_member_id: current_member.id
      )
      @message.mark_read! if @message.inbound? && !@message.read_at
    end

    def new
      @partners = FederationPartner.active.order(name: :asc)
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

      redirect_to federation_hub_messages_path, notice: t("federation_hub.messages.sent")
    rescue ArgumentError => e
      redirect_to new_federation_hub_message_path, alert: e.message
    rescue => e
      redirect_to new_federation_hub_message_path, alert: t("federation_hub.messages.send_failed", error: e.message)
    end
  end
end

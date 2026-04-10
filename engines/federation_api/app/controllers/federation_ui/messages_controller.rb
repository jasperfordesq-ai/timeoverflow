# GET/POST /federation/messages
#
# Allows logged-in members to view their federation messages
# and send outbound messages to remote users.
#
module FederationUi
  class MessagesController < BaseController
    before_action :require_active_member!

    # GET /federation/messages
    def index
      messages = FederationMessage
        .where(local_member_id: current_member.id)
        .order(created_at: :desc)
        .limit(50)

      respond_with_data(messages.map { |m| serialize_message(m) })
    end

    # POST /federation/messages
    def create
      partner = FederationPartner.active.find(params[:partner_id])

      handler = Federation::MessageHandler.new(partner: partner)
      message = handler.send_outbound(
        member: current_member,
        remote_user_identifier: params[:recipient_id] || params[:remote_user_identifier],
        subject: params[:subject],
        body: params[:body],
        organization: current_organization
      )

      respond_with_data(serialize_message(message), status: :created)
    rescue ArgumentError => e
      respond_with_error(e.message, status: :unprocessable_entity)
    rescue ActiveRecord::RecordInvalid => e
      respond_with_error(e.record.errors.full_messages.join(", "), status: :unprocessable_entity)
    end

    private

    def serialize_message(msg)
      {
        id: msg.id,
        direction: msg.direction,
        remote_user_identifier: msg.remote_user_identifier,
        subject: msg.subject,
        body: msg.body,
        status: msg.status,
        delivered_at: msg.delivered_at&.iso8601,
        read_at: msg.read_at&.iso8601,
        created_at: msg.created_at.iso8601
      }
    end
  end
end

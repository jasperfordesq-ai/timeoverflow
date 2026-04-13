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
        .where(organization_id: current_organization.id, local_member_id: current_member.id)
        .order(created_at: :desc)
        .limit(50)

      respond_with_data(messages.map { |m| serialize_message(m) })
    end

    # POST /federation/messages
    def create
      # Body length validation (matches API-level 10,000-char limit)
      if params[:body].present? && params[:body].to_s.length > 10_000
        return respond_with_error(I18n.t("federation_ui.messages.body_too_long", max: 10_000, default: "Message body must be %{max} characters or less"), status: :unprocessable_entity)
      end

      # Org-level federation gate
      unless Federation::AccessControl.org_enabled?(current_organization)
        return respond_with_error(I18n.t("federation_ui.messages.federation_disabled", default: "Federation is not enabled for your organization"), status: :forbidden)
      end

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

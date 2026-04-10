# Federation API: Cross-platform messaging endpoint.
#
# Receives messages from federation partners destined for local members,
# and allows partners to query message status.
#
# Nexus calls: POST /api/v1/messages  (via FederationExternalApiClient::sendMessage)
# Nexus calls: GET  /api/v1/messages  (to retrieve messages)
#
module Api
  module V1
    class MessagesController < BaseController
      before_action -> { require_permission!(:profiles) }
      before_action :validate_message_params!, only: [:create]

      # GET /api/v1/messages/:id
      def show
        message = FederationMessage.find(params[:id])
        respond_with_data(serialize_message(message))
      end

      # GET /api/v1/messages?organization_id=X&member_id=Y
      # Returns messages for a specific member or organization.
      def index
        require_organization!
        return if performed?

        messages = FederationMessage.for_organization(current_organization.id)

        # Filter by member
        if params[:member_id].present?
          messages = messages.for_member(params[:member_id].to_i)
        end

        # Filter by direction
        if params[:direction].present? && FederationMessage::DIRECTIONS.include?(params[:direction])
          messages = messages.where(direction: params[:direction])
        end

        messages = messages.order(created_at: :desc)
        messages, meta = paginate(messages)

        respond_with_data(
          messages.map { |m| serialize_message(m) },
          meta: meta
        )
      end

      # POST /api/v1/messages
      # Receives a message from a federation partner for a local member.
      #
      # Nexus payload: { sender_id, recipient_id, subject, body }
      # Also accepts:  { partner_id, remote_user_identifier, local_member_id,
      #                   local_member_email, local_member_uid, organization_id,
      #                   subject, body, external_message_id }
      def create
        partner = resolve_partner
        return respond_with_error("Unknown or inactive partner", status: :not_found) unless partner&.active?

        # Idempotency: check for duplicate
        if params[:external_message_id].present?
          existing = FederationMessage.find_by(
            federation_partner: partner,
            external_message_id: params[:external_message_id]
          )
          return respond_with_data(serialize_message(existing)) if existing
        end

        # Resolve the local recipient
        org_id = params[:organization_id] || params[:local_organization_id]
        org = org_id.present? ? Organization.find_by(id: org_id) : nil

        member = resolve_local_member(partner, org)
        return respond_with_error("Could not resolve local recipient", status: :unprocessable_entity) unless member

        org ||= member.organization

        # Enforce org-level federation setting.
        unless Federation::AccessControl.org_enabled?(org)
          return respond_with_error("Federation is not enabled for this organization", status: :forbidden)
        end

        # Check member-level federation consent (if preference records exist).
        if FederationMemberPreference.exists?(member_id: member.id)
          unless Federation::AccessControl.member_can_receive_messages?(member, partner: partner)
            return respond_with_error("Recipient has not opted in to federation messaging", status: :forbidden)
          end
        end

        # Create the message
        message = FederationMessage.create!(
          federation_partner: partner,
          organization_id: org.id,
          local_member_id: member.id,
          remote_user_identifier: params[:sender_id] || params[:remote_user_identifier],
          external_message_id: params[:external_message_id],
          direction: "inbound",
          subject: params[:subject],
          body: params[:body],
          status: "delivered",
          delivered_at: Time.current,
          metadata: {
            "sender_name" => params[:sender_name],
            "sender_platform" => partner.platform_type
          }.compact
        )

        # Notify the local member about the received message.
        Federation::NotificationService.notify(
          member: member,
          event_type: :message_received,
          data: { sender_name: params[:sender_name] || message.remote_user_identifier, subject: message.subject, body: message.body, partner_name: partner.name }
        )

        respond_with_data(serialize_message(message), status: :created)

      rescue ActiveRecord::RecordNotUnique
        existing = FederationMessage.find_by(
          federation_partner_id: partner&.id,
          external_message_id: params[:external_message_id]
        )
        if existing
          respond_with_data(serialize_message(existing))
        else
          respond_with_error("Duplicate message", status: :conflict)
        end
      rescue ActiveRecord::RecordInvalid => e
        respond_with_error("Message validation failed", status: :unprocessable_entity,
                           errors: e.record.errors.full_messages)
      end

      private

      def resolve_partner
        if params[:partner_id].present?
          FederationPartner.active.find_by(id: params[:partner_id])
        else
          # Do not guess — require explicit partner identification.
          nil
        end
      end

      def resolve_local_member(partner, org)
        # Try multiple lookup strategies (Nexus sends recipient_id or we accept member fields)
        if params[:local_member_id].present?
          Member.find_by(id: params[:local_member_id], active: true)
        elsif params[:recipient_id].present? && org
          # Nexus sends recipient_id which maps to member_uid or member ID
          org.members.active.find_by(id: params[:recipient_id]) ||
            org.members.active.find_by(member_uid: params[:recipient_id])
        elsif params[:local_member_uid].present? && org
          org.members.active.find_by(member_uid: params[:local_member_uid])
        elsif params[:local_member_email].present?
          user = User.find_by(email: params[:local_member_email])
          user&.members&.active&.find_by(organization: org) if user && org
        else
          nil
        end
      end

      def validate_message_params!
        sender = params[:sender_id] || params[:remote_user_identifier]
        if sender.blank?
          return respond_with_error("Missing sender_id or remote_user_identifier", status: :bad_request)
        end
        if params[:body].blank?
          return respond_with_error("Missing required field: body", status: :bad_request)
        end
        recipient = params[:recipient_id] || params[:local_member_id] || params[:local_member_uid] || params[:local_member_email]
        if recipient.blank?
          return respond_with_error("Missing recipient identifier (recipient_id, local_member_id, local_member_uid, or local_member_email)", status: :bad_request)
        end
      end

      def serialize_message(message)
        {
          id: message.id,
          federation_partner_id: message.federation_partner_id,
          organization_id: message.organization_id,
          local_member_id: message.local_member_id,
          remote_user_identifier: message.remote_user_identifier,
          external_message_id: message.external_message_id,
          direction: message.direction,
          subject: message.subject,
          body: message.body,
          status: message.status,
          delivered_at: message.delivered_at&.iso8601,
          read_at: message.read_at&.iso8601,
          created_at: message.created_at.iso8601
        }
      end
    end
  end
end

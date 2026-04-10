# Handles cross-platform message sending for federation.
#
# Outbound: local member sends a message to a remote user on a partner platform.
# The message is stored locally and delivered via webhook to the partner.
#
module Federation
  class MessageHandler
    def initialize(partner:)
      @partner = partner
    end

    # Send a message from a local member to a remote user.
    # Returns the created FederationMessage record.
    def send_outbound(member:, remote_user_identifier:, subject: nil, body:, organization: nil)
      org = organization || member.organization

      raise ArgumentError, "Partner cannot share profiles" unless @partner.can_share_profiles?
      raise ArgumentError, "Federation is not enabled for this organization" unless Federation::AccessControl.org_enabled?(org)

      message = FederationMessage.create!(
        federation_partner: @partner,
        organization_id: org.id,
        local_member_id: member.id,
        remote_user_identifier: remote_user_identifier,
        external_message_id: "to_msg_#{SecureRandom.hex(8)}",
        direction: "outbound",
        subject: subject,
        body: body,
        status: "pending",
        metadata: {
          "sender_username" => member.user&.username,
          "sender_member_uid" => member.member_uid,
          "organization_name" => org.name
        }.compact
      )

      # Deliver via webhook (async with retries)
      Federation::WebhookSender.send_async(
        partner: @partner,
        event: "message.sent",
        payload: {
          external_message_id: message.external_message_id,
          sender_id: member.id,
          sender_name: member.user&.username,
          recipient_id: remote_user_identifier,
          subject: subject,
          body: body,
          organization_id: org.id,
          organization_name: org.name
        }
      )

      message.deliver!
      message
    end
  end
end

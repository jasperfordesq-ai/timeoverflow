# Handles cross-platform message sending for federation.
#
# Outbound: local member sends a message to a remote user on a partner platform.
#
# Delivery methods (tried in order):
#   1. Direct API call — if partner has api_endpoint + api_key_hash configured,
#      POST directly to the partner's message-receiving endpoint with Bearer auth.
#   2. Webhook — if partner has webhook_url configured, deliver via async webhook
#      with HMAC signature (fire-and-forget with retries).
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

      payload = {
        external_message_id: message.external_message_id,
        sender_id: member.id,
        sender_name: member.user&.username,
        recipient_id: remote_user_identifier,
        subject: subject,
        body: body,
        organization_id: org.id,
        organization_name: org.name
      }

      # Try direct API call first, fall back to webhook
      if @partner.api_endpoint.present? && @partner.api_key_hash.present?
        deliver_via_api(message, payload)
      elsif @partner.webhook_url.present?
        deliver_via_webhook(message, payload)
      else
        Rails.logger.warn("[Federation::MessageHandler] Partner #{@partner.id} has no api_endpoint or webhook_url — message #{message.id} stored but not delivered")
      end

      message.deliver!
      message
    end

    private

    # Direct API call with Bearer token auth — synchronous, simple.
    def deliver_via_api(message, payload)
      client = Federation::PartnerApiClient.new(partner: @partner)
      result = client.post_message(payload)

      if result["success"] == false
        Rails.logger.warn("[Federation::MessageHandler] API delivery failed: #{result['error']}")
      end
    rescue => e
      Rails.logger.error("[Federation::MessageHandler] API delivery error: #{e.class}: #{e.message}")
    end

    # Async webhook with HMAC signature — fire-and-forget with retries.
    def deliver_via_webhook(message, payload)
      Federation::WebhookSender.send_async(
        partner: @partner,
        event: "message.sent",
        payload: payload
      )
    end
  end
end

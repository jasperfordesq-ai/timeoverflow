# Handles cross-platform message sending for federation.
#
# Outbound: local member sends a message to a remote user on a partner platform.
#
# Delivery methods (tried in order):
#   1. Direct API call — if partner has api_endpoint + api_key_hash configured,
#      POST directly to the partner's message-receiving endpoint with Bearer auth.
#      Message marked "delivered" only on success; stays "pending" on failure.
#   2. Webhook — if partner has webhook_url configured, deliver via async webhook
#      with HMAC signature (fire-and-forget with retries). Message marked "delivered"
#      optimistically since webhook delivery is async.
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
        delivered = deliver_via_api(message, payload)
        message.deliver! if delivered
      elsif @partner.webhook_url.present?
        deliver_via_webhook(message, payload)
        message.deliver! # Optimistic — webhook delivery is async with retries
      else
        Rails.logger.warn("[Federation::MessageHandler] Partner #{@partner.id} has no api_endpoint or webhook_url — message #{message.id} stored but not delivered")
      end

      message
    end

    private

    # Direct API call with Bearer token auth — synchronous.
    # Returns true if delivery succeeded, false otherwise.
    def deliver_via_api(message, payload)
      client = Federation::PartnerApiClient.new(partner: @partner)
      result = client.post_message(payload)

      # Check both top-level failure and nested result rejection
      inner_result = result.dig("data", "result") || {}
      rejected = result["success"] == false ||
                 inner_result["status"] == "rejected" ||
                 inner_result["success"] == false

      if rejected
        error = inner_result["reason"] || inner_result["error"] || result["error"] || "Unknown delivery error"
        Rails.logger.warn("[Federation::MessageHandler] API delivery failed for message #{message.id}: #{error}")
        message.update!(metadata: (message.metadata || {}).merge(
          "delivery_error" => error,
          "delivery_attempted_at" => Time.current.iso8601
        ))
        message.update!(status: "failed") if inner_result["status"] == "rejected"
        return false
      end

      true
    rescue => e
      Rails.logger.error("[Federation::MessageHandler] API delivery error for message #{message.id}: #{e.class}: #{e.message}")
      message.update!(metadata: (message.metadata || {}).merge("delivery_error" => "#{e.class}: #{e.message}", "delivery_attempted_at" => Time.current.iso8601))
      false
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

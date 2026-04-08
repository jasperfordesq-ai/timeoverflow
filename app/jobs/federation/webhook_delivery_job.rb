# Async webhook delivery job for federation events.
#
# Retries up to 3 times with exponential backoff.
#
module Federation
  class WebhookDeliveryJob < ActiveJob::Base
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(partner_id, event, payload)
      partner = FederationPartner.find(partner_id)
      return unless partner.active? && partner.webhook_url.present?

      WebhookSender.send_now(
        partner: partner,
        event: event,
        payload: payload
      )
    end
  end
end

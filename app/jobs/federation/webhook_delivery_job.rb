# Async webhook delivery job for federation events.
#
# Retries up to 3 times with exponential backoff.
#
# For outbound "transaction.requested" events, the FederationTransaction is left
# as "pending" until this job confirms successful delivery, at which point it
# calls complete! to finalise the record. If all retries exhaust, the transaction
# remains pending and ReconciliationJob will reverse it after 24 hours.
#
module Federation
  class WebhookDeliveryJob < ActiveJob::Base
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    # fed_txn_id is optional — only passed for outbound "transaction.requested"
    def perform(partner_id, event, payload, fed_txn_id = nil)
      partner = FederationPartner.find(partner_id)
      return unless partner.active? && partner.webhook_url.present?

      WebhookSender.send_now(
        partner: partner,
        event: event,
        payload: payload
      )

      # For outbound transactions: mark complete only after confirmed delivery.
      # The local Transfer was committed before this job was queued; this step
      # finalises the FederationTransaction status so reconciliation knows it's
      # done and won't attempt a reversal.
      if fed_txn_id && event == "transaction.requested"
        fed_txn = FederationTransaction.find_by(id: fed_txn_id)
        if fed_txn&.pending?
          fed_txn.complete!
          Rails.logger.info("[Federation::WebhookDelivery] Completed fed_txn #{fed_txn_id} after confirmed delivery")
        end
      end
    end
  end
end

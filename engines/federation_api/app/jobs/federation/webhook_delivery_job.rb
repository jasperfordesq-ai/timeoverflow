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
    queue_as :federation

    # M8: Log and alert when all retries are exhausted so ops can investigate.
    # The FederationTransaction stays "pending" and ReconciliationJob will
    # reverse it after 24 hours — this makes the permanent failure visible.
    retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
      partner_id, event, _payload, fed_txn_id = job.arguments
      Rails.logger.error(
        "[Federation::WebhookDelivery][EXHAUSTED] Permanently failed after 3 attempts. " \
        "Partner=#{partner_id} Event=#{event} FedTxn=#{fed_txn_id || 'n/a'} " \
        "Error=#{error.class}: #{error.message}"
      )
      if fed_txn_id.present?
        Rails.logger.error(
          "[Federation::WebhookDelivery][EXHAUSTED] FederationTransaction #{fed_txn_id} will " \
          "remain pending — ReconciliationJob will auto-reverse after 24 h"
        )
      end
      # Hook: add Sentry/PagerDuty/Slack alerting here, e.g.:
      # Sentry.capture_exception(error, extra: { partner_id: partner_id, fed_txn_id: fed_txn_id }) rescue nil
    end

    # fed_txn_id is optional — only passed for outbound "transaction.requested"
    def perform(partner_id, event, payload, fed_txn_id = nil)
      partner = FederationPartner.find(partner_id)

      unless partner.active?
        Rails.logger.warn("[Federation::WebhookDelivery] Partner #{partner_id} is #{partner.status}; dropping #{event} webhook")
        # For outbound transactions, mark disputed so it's visible instead of silently pending
        if fed_txn_id && event == "transaction.requested"
          fed_txn = FederationTransaction.find_by(id: fed_txn_id)
          if fed_txn&.pending?
            fed_txn.update!(
              status: "disputed",
              metadata: (fed_txn.metadata || {}).merge(
                "dispute_reason" => "Partner deactivated before webhook delivery",
                "disputed_at" => Time.current.iso8601
              )
            )
          end
        end
        return
      end

      return unless partner.webhook_url.present?

      WebhookSender.send_now(
        partner: partner,
        event: event,
        payload: payload
      )

      # For outbound transactions: mark complete only after confirmed delivery.
      # The local Transfer was committed and linked in initiate_outbound;
      # complete! called with no args will NOT overwrite transfer_id (idempotency
      # guard added to FederationTransaction#complete!).
      if fed_txn_id && event == "transaction.requested"
        fed_txn = FederationTransaction.find_by(id: fed_txn_id)
        if fed_txn&.pending?
          begin
            fed_txn.complete!
            Rails.logger.info("[Federation::WebhookDelivery] Completed fed_txn #{fed_txn_id} after confirmed delivery")
          rescue => e
            # L2: Completing the federation record failed — log but don't re-raise.
            # The webhook was delivered successfully; the record can be reconciled
            # manually or via ReconciliationJob.
            Rails.logger.error(
              "[Federation::WebhookDelivery] Webhook delivered but failed to complete " \
              "fed_txn #{fed_txn_id}: #{e.class}: #{e.message}"
            )
          end
        end
      end
    end
  end
end

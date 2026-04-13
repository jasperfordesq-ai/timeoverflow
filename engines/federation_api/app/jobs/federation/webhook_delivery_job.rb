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

    # Log and alert when all retries are exhausted so ops can investigate.
    # The FederationTransaction stays "pending" and ReconciliationJob will
    # reverse it after 24 hours — this makes the permanent failure visible.
    retry_on StandardError, wait: :polynomially_longer, attempts: 3 do |job, error|
      partner_id, event, _payload, fed_txn_id = job.arguments
      Rails.logger.error(
        "[Federation::WebhookDelivery][EXHAUSTED] Permanently failed after 3 attempts. " \
        "Partner=#{partner_id} Event=#{event} FedTxn=#{fed_txn_id || 'n/a'} " \
        "Error=#{error.class}: #{error.message}"
      )
      # Record the failure once after all retries are spent (not per-attempt)
      # to avoid prematurely suspending partners.
      partner = FederationPartner.find_by(id: partner_id)
      partner&.record_failure! if partner
      if fed_txn_id.present?
        Rails.logger.error(
          "[Federation::WebhookDelivery][EXHAUSTED] FederationTransaction #{fed_txn_id} will " \
          "remain pending — ReconciliationJob will auto-reverse after 24 h"
        )
      end
      # Attempt to send alert via Sentry if available
      if defined?(Sentry)
        Sentry.capture_exception(error, extra: { partner_id: partner_id, event: event, fed_txn_id: fed_txn_id }) rescue nil
      end
      # Record exhaustion in audit log for admin visibility
      begin
        FederationAuditLog.create!(
          action: "webhook_delivery_exhausted",
          actor_email: "system",
          actor_id: nil,
          target_type: "FederationPartner",
          target_id: partner_id,
          changes_made: { event: event, fed_txn_id: fed_txn_id, error: "#{error.class}: #{error.message}" }
        )
      rescue => log_err
        Rails.logger.warn("[Federation::WebhookDelivery] Could not create audit log: #{log_err.message}")
      end
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

      response = WebhookSender.send_now(
        partner: partner,
        event: event,
        payload: payload
      )

      # Handle nil response (partner has no webhook_url configured or deliver returned nil)
      if response.nil?
        Rails.logger.error("[Federation::WebhookDelivery] No response from webhook delivery — partner may have no webhook_url")
        if fed_txn_id
          fed_txn = FederationTransaction.find_by(id: fed_txn_id)
          fed_txn&.update(status: "disputed", metadata: (fed_txn.metadata || {}).merge("disputed_reason" => "Partner has no webhook_url"))
        end
        return
      end

      # For outbound transactions: mark complete only after confirmed delivery.
      # The local Transfer was committed and linked in initiate_outbound;
      # complete! called with no args will NOT overwrite transfer_id (idempotency
      # guard added to FederationTransaction#complete!).
      if fed_txn_id && event == "transaction.requested"
        fed_txn = FederationTransaction.find_by(id: fed_txn_id)
        if fed_txn&.pending?
          # Check that the partner actually accepted the transaction.
          # HTTP 2xx alone isn't enough — the response body may indicate rejection.
          partner_accepted = true
          begin
            begin
              raw_body = response.body.present? ? response.body.dup.force_encoding("UTF-8") : nil
              body = raw_body ? JSON.parse(raw_body) : {}
            rescue JSON::ParserError, TypeError, Encoding::InvalidByteSequenceError => json_err
              Rails.logger.warn("[Federation::WebhookDelivery] Failed to parse response body as JSON: #{json_err.message}")
              body = nil
            end
            if body.nil?
              # Non-JSON response (e.g., HTML error page) — treat as rejection
              partner_accepted = false
              Rails.logger.warn(
                "[Federation::WebhookDelivery] Partner returned non-JSON response for fed_txn #{fed_txn_id} — treating as rejection"
              )
              fed_txn.update!(
                status: "disputed",
                metadata: (fed_txn.metadata || {}).merge(
                  "dispute_reason" => "Partner returned non-JSON response",
                  "disputed_at" => Time.current.iso8601
                )
              )
            elsif body.is_a?(Hash) && body.key?("success") && body["success"] == false
              partner_accepted = false
              Rails.logger.warn(
                "[Federation::WebhookDelivery] Partner returned success=false for fed_txn #{fed_txn_id}: #{body["error"]}"
              )
              fed_txn.update!(
                status: "disputed",
                metadata: (fed_txn.metadata || {}).merge(
                  "dispute_reason" => "Partner rejected transaction: #{body["error"]}",
                  "disputed_at" => Time.current.iso8601
                )
              )
            end
          rescue => e
            Rails.logger.warn("[Federation::WebhookDelivery] Could not parse partner response body: #{e.message}")
          end

          if partner_accepted
            # Lock the row to prevent ReconciliationJob from concurrently
            # modifying state between our reload and update.
            fed_txn.with_lock do
              if !fed_txn.pending?
                Rails.logger.info(
                  "[Federation::WebhookDelivery] Fed_txn #{fed_txn_id} is now #{fed_txn.status} (changed during delivery) — skipping completion"
                )
              elsif fed_txn.metadata&.dig("reversal_transfer_id").present?
                Rails.logger.warn(
                  "[Federation::WebhookDelivery] Fed_txn #{fed_txn_id} was reversed while webhook was in flight — marking disputed"
                )
                fed_txn.update!(
                  status: "disputed",
                  metadata: (fed_txn.metadata || {}).merge(
                    "dispute_reason" => "Reversal occurred before webhook delivery completed",
                    "disputed_at" => Time.current.iso8601
                  )
                )
              else
                fed_txn.complete!
                Rails.logger.info("[Federation::WebhookDelivery] Completed fed_txn #{fed_txn_id} after confirmed delivery")
              end
            end
          end
        end
      end
    end
  end
end

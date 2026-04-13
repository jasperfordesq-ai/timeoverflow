module FederationAdmin
  class ActivityController < BaseController
    def index
      # Combine recent events from multiple sources into a unified timeline.
      @events = []

      # Recent transactions
      FederationTransaction.includes(:federation_partner).order(created_at: :desc).limit(20).each do |txn|
        @events << {
          timestamp: txn.created_at,
          type: "transaction",
          icon: txn.direction == "inbound" ? "arrow-down" : "arrow-up",
          title: "#{txn.direction.capitalize} transfer — #{(txn.amount / 3600.0).round(1)}h",
          subtitle: "Partner: #{txn.federation_partner&.name} | Status: #{txn.status}",
          status: txn.status,
          link: federation_admin_transaction_path(txn)
        }
      end

      # Recent messages
      begin
        FederationMessage.includes(:federation_partner).order(created_at: :desc).limit(20).each do |msg|
          @events << {
            timestamp: msg.created_at,
            type: "message",
            icon: msg.direction == "inbound" ? "mail-in" : "mail-out",
            title: "#{msg.direction.capitalize} message#{msg.subject.present? ? ": #{msg.subject.truncate(50)}" : ""}",
            subtitle: "Partner: #{msg.federation_partner&.name} | To: #{msg.remote_user_identifier}",
            status: msg.status,
            link: federation_admin_message_path(msg)
          }
        end
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("[FederationAdmin] FederationMessage query failed (table may not exist): #{e.message}")
      end

      # Recent webhook logs
      FederationWebhookLog.includes(:federation_partner).order(created_at: :desc).limit(20).each do |log|
        @events << {
          timestamp: log.created_at,
          type: "webhook",
          icon: log.direction == "inbound" ? "bell" : "broadcast",
          title: "#{log.direction.capitalize} webhook: #{log.event_type}",
          subtitle: "Partner: #{log.federation_partner&.name} | HTTP #{log.response_code || '—'}",
          status: log.status,
          link: federation_admin_webhook_log_path(log)
        }
      end

      # Sort all events by timestamp descending
      @events.sort_by! { |e| e[:timestamp] }.reverse!

      # M15: Pagination — limit to 50 per page
      per_page = 50
      @current_page = [(params[:page] || 1).to_i, 1].max
      @total_pages = (@events.size.to_f / per_page).ceil
      @total_pages = 1 if @total_pages < 1
      @current_page = [@current_page, @total_pages].min
      @events = @events.slice((@current_page - 1) * per_page, per_page) || []
    end
  end
end

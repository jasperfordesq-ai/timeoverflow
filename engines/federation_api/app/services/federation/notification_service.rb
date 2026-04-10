module Federation
  class NotificationService
    # Notify a member about a federation event.
    # Fails silently if host notification systems aren't available.
    def self.notify(member:, event_type:, data: {})
      case event_type
      when :message_received
        notify_message_received(member, data)
      when :transfer_received
        notify_transfer_received(member, data)
      when :transfer_sent
        notify_transfer_sent(member, data)
      end
    rescue => e
      Rails.logger.error("[Federation::NotificationService] Failed to notify member #{member.id}: #{e.class}: #{e.message}")
    end

    private

    def self.notify_message_received(member, data)
      user = member.user
      return unless user&.email.present?

      # Send email notification
      Federation::NotificationMailer.message_received(
        to: user.email,
        member: member,
        sender_name: data[:sender_name] || data[:remote_user_identifier] || "A federation partner",
        subject: data[:subject],
        body_preview: data[:body].to_s.truncate(200),
        partner_name: data[:partner_name]
      ).deliver_later rescue Rails.logger.warn("[Federation::Notification] Email delivery failed for member #{member.id}")
    end

    def self.notify_transfer_received(member, data)
      user = member.user
      return unless user&.email.present?

      hours = (data[:amount].to_i / 3600.0).round(1)

      Federation::NotificationMailer.transfer_received(
        to: user.email,
        member: member,
        amount_hours: hours,
        sender_name: data[:remote_user_identifier] || "A federation partner",
        reason: data[:reason],
        partner_name: data[:partner_name]
      ).deliver_later rescue Rails.logger.warn("[Federation::Notification] Email delivery failed for member #{member.id}")
    end

    def self.notify_transfer_sent(member, data)
      user = member.user
      return unless user&.email.present?

      hours = (data[:amount].to_i / 3600.0).round(1)

      Federation::NotificationMailer.transfer_sent(
        to: user.email,
        member: member,
        amount_hours: hours,
        recipient_name: data[:remote_user_identifier] || "A federation partner",
        reason: data[:reason],
        partner_name: data[:partner_name]
      ).deliver_later rescue Rails.logger.warn("[Federation::Notification] Email delivery failed for member #{member.id}")
    end
  end
end

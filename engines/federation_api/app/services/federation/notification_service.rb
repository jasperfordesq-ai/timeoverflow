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
      unless user&.email.present?
        Rails.logger.info("[Federation::NotificationService] Skipping message_received notification for member #{member.id}: #{user ? 'email is blank' : 'no associated user'}")
        return
      end

      # Send email notification.
      # Sender name falls back to I18n default if not provided by the partner.
      sender = data[:sender_name] || data[:remote_user_identifier] || I18n.t("federation_mailer.common.default_name")

      Federation::NotificationMailer.message_received(
        to: user.email,
        member: member,
        sender_name: sender,
        subject: data[:subject],
        body_preview: data[:body].to_s.truncate(200),
        partner_name: data[:partner_name]
      ).deliver_later rescue Rails.logger.warn("[Federation::Notification] Email delivery failed for member #{member.id}")
    end

    def self.notify_transfer_received(member, data)
      user = member.user
      unless user&.email.present?
        Rails.logger.info("[Federation::NotificationService] Skipping transfer_received notification for member #{member.id}: #{user ? 'email is blank' : 'no associated user'}")
        return
      end

      raw_amount = data[:amount]
      unless raw_amount.is_a?(Numeric) || raw_amount.to_s.match?(/\A-?\d+(\.\d+)?\z/)
        Rails.logger.warn("[Federation::NotificationService] Invalid or missing amount (#{raw_amount.inspect}) for transfer_received notification — defaulting to 0")
        raw_amount = 0
      end
      hours = (raw_amount.to_i / 3600.0).round(1)
      sender = data[:remote_user_identifier] || I18n.t("federation_mailer.common.default_name")

      Federation::NotificationMailer.transfer_received(
        to: user.email,
        member: member,
        amount_hours: hours,
        sender_name: sender,
        reason: data[:reason],
        partner_name: data[:partner_name]
      ).deliver_later rescue Rails.logger.warn("[Federation::Notification] Email delivery failed for member #{member.id}")
    end

    def self.notify_transfer_sent(member, data)
      user = member.user
      unless user&.email.present?
        Rails.logger.info("[Federation::NotificationService] Skipping transfer_sent notification for member #{member.id}: #{user ? 'email is blank' : 'no associated user'}")
        return
      end

      raw_amount = data[:amount]
      unless raw_amount.is_a?(Numeric) || raw_amount.to_s.match?(/\A-?\d+(\.\d+)?\z/)
        Rails.logger.warn("[Federation::NotificationService] Invalid or missing amount (#{raw_amount.inspect}) for transfer_sent notification — defaulting to 0")
        raw_amount = 0
      end
      hours = (raw_amount.to_i / 3600.0).round(1)
      recipient = data[:remote_user_identifier] || I18n.t("federation_mailer.common.default_name")

      Federation::NotificationMailer.transfer_sent(
        to: user.email,
        member: member,
        amount_hours: hours,
        recipient_name: recipient,
        reason: data[:reason],
        partner_name: data[:partner_name]
      ).deliver_later rescue Rails.logger.warn("[Federation::Notification] Email delivery failed for member #{member.id}")
    end
  end
end

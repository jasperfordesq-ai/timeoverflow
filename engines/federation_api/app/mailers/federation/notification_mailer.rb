module Federation
  class NotificationMailer < ActionMailer::Base
    default from: -> { ENV.fetch("FEDERATION_EMAIL_FROM", "federation@timeoverflow.org") }
    layout false  # Plain text emails, no host app layout dependency

    def message_received(to:, member:, sender_name:, subject:, body_preview:, partner_name:)
      @member = member
      @sender_name = sender_name
      @subject = subject
      @body_preview = body_preview
      @partner_name = partner_name

      I18n.with_locale(member.user&.locale || I18n.default_locale) do
        mail(
          to: to,
          subject: I18n.t("federation_mailer.message_received.subject", sender_name: sender_name, default: "[Federation] New message from %{sender_name}")
        )
      end
    end

    def transfer_received(to:, member:, amount_hours:, sender_name:, reason:, partner_name:)
      @member = member
      @amount_hours = amount_hours
      @sender_name = sender_name
      @reason = reason
      @partner_name = partner_name

      I18n.with_locale(member.user&.locale || I18n.default_locale) do
        mail(
          to: to,
          subject: I18n.t("federation_mailer.transfer_received.subject", amount: amount_hours, sender_name: sender_name, default: "[Federation] You received %{amount} hours from %{sender_name}")
        )
      end
    end

    def transfer_sent(to:, member:, amount_hours:, recipient_name:, reason:, partner_name:)
      @member = member
      @amount_hours = amount_hours
      @recipient_name = recipient_name
      @reason = reason
      @partner_name = partner_name

      I18n.with_locale(member.user&.locale || I18n.default_locale) do
        mail(
          to: to,
          subject: I18n.t("federation_mailer.transfer_sent.subject", amount: amount_hours, recipient_name: recipient_name, default: "[Federation] You sent %{amount} hours to %{recipient_name}")
        )
      end
    end
  end
end

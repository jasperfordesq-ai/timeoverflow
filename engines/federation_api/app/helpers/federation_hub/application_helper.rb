# Helpers for Federation Hub views.
# Uses Bootstrap 5 classes (NOT Tailwind) to match the host app's design.
#
module FederationHub
  module ApplicationHelper
    def federation_status_badge(status)
      css = case status.to_s
            when "active", "completed"    then "bg-success"
            when "pending"                then "bg-warning text-dark"
            when "suspended", "cancelled" then "bg-secondary"
            when "terminated", "failed"   then "bg-danger"
            else "bg-secondary"
            end
      content_tag(:span, status.to_s.capitalize, class: "badge #{css}")
    end

    def partnership_level_badge(level, name)
      unless level.is_a?(Integer) && level.between?(1, 4)
        return content_tag(:span, "Unknown", class: "badge bg-secondary")
      end
      css = case level
            when 4 then "bg-primary"
            when 3 then "bg-info"
            when 2 then "bg-success"
            else "bg-secondary"
            end
      content_tag(:span, "L#{level} \u2014 #{name}", class: "badge #{css}")
    end

    def federation_feature_icon(enabled)
      if enabled
        label = t("federation_hub.common.enabled", default: "Enabled")
        content_tag(:span, "\u2713", class: "text-success fw-bold", title: label, role: "img", "aria-label": label)
      else
        label = t("federation_hub.common.disabled", default: "Disabled")
        content_tag(:span, "\u2717", class: "text-muted", title: label, role: "img", "aria-label": label)
      end
    end

    def format_date(datetime)
      return "\u2014" unless datetime
      l(datetime, format: :long, default: datetime.in_time_zone.strftime("%Y-%m-%d %H:%M %Z"))
    rescue I18n::ArgumentError, StandardError
      datetime.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")
    end

    def format_federation_hours(seconds)
      suffix = t("federation_hub.transfers.hours_short", default: "h")
      return "0.0#{suffix}" unless seconds.is_a?(Numeric) && seconds > 0
      "#{(seconds.to_f / 3600).round(1)}#{suffix}"
    end
  end
end

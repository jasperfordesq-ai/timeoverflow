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
        content_tag(:span, "\u2713", class: "text-success fw-bold", title: "Enabled")
      else
        content_tag(:span, "\u2717", class: "text-muted", title: "Disabled")
      end
    end

    def format_federation_hours(seconds)
      return "0h" unless seconds && seconds > 0
      "#{(seconds.to_f / 3600).round(1)}h"
    end
  end
end

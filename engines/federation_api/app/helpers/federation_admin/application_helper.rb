module FederationAdmin
  module ApplicationHelper
    def status_badge_class(status)
      case status.to_s
      when "active", "completed", "success", "delivered", "read"
        "bg-green-100 text-green-800"
      when "pending"
        "bg-yellow-100 text-yellow-800"
      when "suspended", "cancelled"
        "bg-gray-100 text-gray-800"
      when "terminated", "failed", "disputed"
        "bg-red-100 text-red-800"
      else
        "bg-gray-100 text-gray-600"
      end
    end

    def direction_badge_class(direction)
      case direction.to_s
      when "inbound"
        "bg-green-100 text-green-800"
      when "outbound"
        "bg-blue-100 text-blue-800"
      else
        "bg-gray-100 text-gray-600"
      end
    end

    def format_date(datetime)
      return "—" unless datetime
      l(datetime, format: :long, default: datetime.in_time_zone.strftime("%Y-%m-%d %H:%M %Z"))
    rescue
      datetime.in_time_zone.strftime("%Y-%m-%d %H:%M %Z")
    end

    def format_hours(seconds)
      return "0h" unless seconds
      "#{(seconds.to_f / 3600).round(1)}h"
    end

    def sort_link(label, column, current_sort, current_dir)
      new_dir = (current_sort == column.to_s && current_dir != "asc") ? "asc" : "desc"
      arrow = if current_sort == column.to_s
        current_dir == "asc" ? " \u2191" : " \u2193"
      else
        ""
      end
      safe_params = { sort: column, dir: new_dir, page: request.query_parameters[:page] }.compact
      link_to "#{label}#{arrow}", "?#{safe_params.to_query}", class: "hover:text-federation-600"
    end
  end
end

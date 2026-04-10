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
      datetime.strftime("%Y-%m-%d %H:%M UTC")
    end

    def format_hours(seconds)
      return "0h" unless seconds
      "#{(seconds.to_f / 3600).round(1)}h"
    end
  end
end

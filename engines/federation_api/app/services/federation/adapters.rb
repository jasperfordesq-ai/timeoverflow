# Federation protocol adapter registry.
#
# Resolves a partner's protocol_type to the appropriate adapter class.
# Mirrors Nexus's resolveAdapter() / createAdapter() pattern.
#
# Usage:
#   adapter = Federation::Adapters.resolve(partner)
#   adapter.map_endpoint("members")  # => "/members" (REST) or "/accounts" (JSON:API)
#
module Federation
  module Adapters
    REGISTRY = {
      "rest"           => "Federation::Adapters::RestAdapter",
      "json_api"       => "Federation::Adapters::JsonApiAdapter",
      "credit_commons" => "Federation::Adapters::CreditCommonsAdapter"
    }.freeze

    # Resolve a partner to its protocol adapter instance.
    def self.resolve(partner)
      protocol = partner.respond_to?(:protocol_type) ? partner.protocol_type : "rest"
      klass_name = REGISTRY[protocol.to_s]
      raise ArgumentError, "Unknown protocol_type: #{protocol}. Supported: #{REGISTRY.keys.join(', ')}" unless klass_name
      klass_name.constantize.new(partner: partner)
    end

    # List all supported protocol types.
    def self.supported_protocols
      REGISTRY.keys
    end

    # Human-readable labels for admin UI.
    def self.protocol_labels
      {
        "rest"           => "REST (TimeOverflow / Nexus native)",
        "json_api"       => "JSON:API (Komunitin)",
        "credit_commons" => "Credit Commons"
      }.freeze
    end
  end
end

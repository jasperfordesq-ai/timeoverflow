# Abstract base class for federation protocol adapters.
#
# Every protocol adapter (REST, JSON:API, Credit Commons) inherits from this
# and implements all methods. The interface mirrors Nexus's FederationProtocolAdapter
# contract for cross-platform consistency.
#
# Adapters handle:
#   - Endpoint mapping (action → URL path)
#   - Data transformation (outbound: TO format → protocol format)
#   - Data transformation (inbound: protocol format → TO format)
#   - Webhook event normalisation
#   - Response envelope unwrapping
#   - Content type negotiation
#
module Federation
  module Adapters
    class BaseAdapter
      attr_reader :partner

      def initialize(partner:)
        @partner = partner
      end

      # --- Identity ---

      # Human-readable protocol name (e.g., "REST", "JSON:API", "Credit Commons")
      def protocol_name
        raise NotImplementedError, "#{self.class}#protocol_name"
      end

      # Default API path prefix (e.g., "/api/v1", "/accounting")
      def default_api_path
        raise NotImplementedError, "#{self.class}#default_api_path"
      end

      # MIME type for requests/responses
      def content_type
        "application/json"
      end

      # --- Endpoint mapping ---

      # Map a logical action to a protocol-specific URL path.
      # action: "members", "listings", "transfers", "messages", "health", etc.
      # params: optional hash (e.g., { id: 123 } for single-resource endpoints)
      def map_endpoint(action, params = {})
        raise NotImplementedError, "#{self.class}#map_endpoint"
      end

      # Override HTTP method if the protocol requires it (e.g., PATCH instead of POST)
      def map_http_method(action, default = "POST")
        default
      end

      # --- Outbound transformation (TO → protocol format) ---

      def transform_outbound_transfer(payload)
        raise NotImplementedError, "#{self.class}#transform_outbound_transfer"
      end

      def transform_outbound_message(payload)
        raise NotImplementedError, "#{self.class}#transform_outbound_message"
      end

      # --- Inbound transformation (protocol format → TO format) ---

      def transform_inbound_member(data)
        raise NotImplementedError, "#{self.class}#transform_inbound_member"
      end

      def transform_inbound_members(data)
        raise NotImplementedError, "#{self.class}#transform_inbound_members"
      end

      def transform_inbound_listing(data)
        raise NotImplementedError, "#{self.class}#transform_inbound_listing"
      end

      def transform_inbound_listings(data)
        raise NotImplementedError, "#{self.class}#transform_inbound_listings"
      end

      def transform_inbound_transfer(data)
        raise NotImplementedError, "#{self.class}#transform_inbound_transfer"
      end

      # --- Webhook normalisation ---

      # Map a protocol-specific event name to the canonical TO event name.
      # e.g., Komunitin "transfer.committed" → TO "transaction.completed"
      def normalize_webhook_event(event)
        event # Default: pass through unchanged
      end

      # Normalise a protocol-specific webhook payload to canonical format.
      def normalize_webhook_payload(payload)
        payload # Default: pass through unchanged
      end

      # --- Response handling ---

      # Extract the data payload from a protocol-specific response envelope.
      # REST: { "success": true, "data": [...] } → [...]
      # JSON:API: { "data": [{ "type": "...", "attributes": {...} }] } → [...]
      def unwrap_response(response)
        raise NotImplementedError, "#{self.class}#unwrap_response"
      end

      # Serialize data into the protocol's response envelope format.
      def serialize_response(data, meta: {}, resource_type: nil)
        raise NotImplementedError, "#{self.class}#serialize_response"
      end

      # Serialize an error into the protocol's error format.
      def serialize_error(message, status: nil, errors: nil, meta: {})
        raise NotImplementedError, "#{self.class}#serialize_error"
      end

      # --- Extra headers for outbound requests ---

      def extra_headers
        {}
      end
    end
  end
end

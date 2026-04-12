# REST protocol adapter — the default for TimeOverflow and Nexus partners.
#
# Passthrough adapter: all transform methods return data unchanged.
# This mirrors Nexus's NexusAdapter which is also a no-op passthrough.
#
# The REST adapter uses the standard TimeOverflow JSON envelope:
#   { "success": true, "data": {...}, "meta": {...} }
#
module Federation
  module Adapters
    class RestAdapter < BaseAdapter
      def protocol_name
        "REST"
      end

      def default_api_path
        "/api/v1"
      end

      def content_type
        "application/json"
      end

      # --- Endpoint mapping (direct — paths match TO API) ---

      def map_endpoint(action, params = {})
        case action.to_s
        when "members"       then "/members"
        when "member"        then "/members/#{params[:id]}"
        when "listings"      then "/listings"
        when "listing"       then "/listings/#{params[:id]}"
        when "offers"        then "/offers"
        when "inquiries"     then "/inquiries"
        when "transfers"     then "/transfers"
        when "transfer"      then "/transfers/#{params[:id]}"
        when "transactions"  then "/transfers"  # Nexus compatibility alias
        when "messages"      then "/messages"
        when "health"        then "/health"
        when "organizations" then "/organizations"
        when "accounts"      then "/accounts/#{params[:id]}"
        when "receive"       then "/receive"  # webhook/message receiver
        else "/#{action}"
        end
      end

      # --- Outbound: passthrough (TO format is the native format) ---

      def transform_outbound_transfer(payload)
        payload
      end

      def transform_outbound_message(payload)
        payload
      end

      # --- Inbound: passthrough ---

      def transform_inbound_member(data)
        data
      end

      def transform_inbound_members(data)
        data
      end

      def transform_inbound_listing(data)
        data
      end

      def transform_inbound_listings(data)
        data
      end

      def transform_inbound_transfer(data)
        data
      end

      # --- Response handling ---

      def unwrap_response(response)
        # REST envelope: { "success" => true, "data" => [...], "meta" => {...} }
        if response.is_a?(Hash) && response.key?("data")
          response["data"]
        else
          response
        end
      end

      def serialize_response(data, meta: {}, resource_type: nil)
        { success: true, data: data, meta: meta }
      end

      def serialize_error(message, status: nil, errors: nil, meta: {})
        body = { success: false, error: message, meta: meta }
        body[:errors] = errors if errors.present?
        body
      end
    end
  end
end

# JSON:API protocol adapter for Komunitin compatibility.
#
# Handles serialisation/deserialisation of JSON:API documents
# (application/vnd.api+json) and field mapping between Komunitin's
# accounting model and TimeOverflow's federation model.
#
# Phase 1 implementation — stub for now, full implementation follows.
#
module Federation
  module Adapters
    class JsonApiAdapter < BaseAdapter
      def protocol_name
        "JSON:API"
      end

      def default_api_path
        "/accounting"
      end

      def content_type
        "application/vnd.api+json"
      end

      # --- Endpoint mapping (Komunitin paths) ---

      def map_endpoint(action, params = {})
        currency_code = @partner&.metadata&.dig("currency_code") || "default"
        case action.to_s
        when "members", "accounts" then "/#{currency_code}/accounts"
        when "member", "account"  then "/#{currency_code}/accounts/#{params[:id]}"
        when "transfers"          then "/#{currency_code}/transfers"
        when "transfer"           then "/#{currency_code}/transfers/#{params[:id]}"
        when "listings"           then "/#{currency_code}/accounts" # Komunitin has no listings
        when "health"             then "/currencies"
        when "messages"           then "/messages" # Not in Komunitin spec — custom extension
        else "/#{action}"
        end
      end

      def extra_headers
        { "Accept" => "application/vnd.api+json", "Content-Type" => "application/vnd.api+json" }
      end

      # --- Outbound transformation (TO seconds → Komunitin minor units) ---

      def transform_outbound_transfer(payload)
        # TODO Phase 1: wrap in JSON:API document, convert seconds → minor units
        payload
      end

      def transform_outbound_message(payload)
        # TODO Phase 1: wrap in JSON:API document
        payload
      end

      # --- Inbound transformation (Komunitin → TO format) ---

      def transform_inbound_member(data)
        # TODO Phase 1: extract from JSON:API attributes, map account code → member
        data
      end

      def transform_inbound_members(data)
        # TODO Phase 1: unwrap JSON:API collection
        data
      end

      def transform_inbound_listing(data)
        data
      end

      def transform_inbound_listings(data)
        data
      end

      def transform_inbound_transfer(data)
        # TODO Phase 1: convert minor units → seconds, map states
        data
      end

      # --- Response handling ---

      def unwrap_response(response)
        # JSON:API envelope: { "data" => [...] } or { "data" => { "type" => ..., "attributes" => ... } }
        if response.is_a?(Hash) && response.key?("data")
          data = response["data"]
          if data.is_a?(Array)
            data.map { |r| r.is_a?(Hash) && r.key?("attributes") ? r["attributes"].merge("id" => r["id"]) : r }
          elsif data.is_a?(Hash) && data.key?("attributes")
            data["attributes"].merge("id" => data["id"])
          else
            data
          end
        else
          response
        end
      end

      def serialize_response(data, meta: {}, resource_type: nil)
        # TODO Phase 1: full JSON:API document construction
        type = resource_type || "resources"
        if data.is_a?(Array)
          {
            data: data.map { |item| { type: type, id: item[:id]&.to_s, attributes: item.except(:id) } },
            meta: meta
          }
        else
          {
            data: { type: type, id: data[:id]&.to_s, attributes: data.is_a?(Hash) ? data.except(:id) : data },
            meta: meta
          }
        end
      end

      def serialize_error(message, status: nil, errors: nil)
        {
          errors: [
            { status: status.to_s, title: "Error", detail: message }
          ].concat(
            (errors || []).map { |e| { status: status.to_s, detail: e.is_a?(Hash) ? e[:code] : e.to_s } }
          )
        }
      end
    end
  end
end

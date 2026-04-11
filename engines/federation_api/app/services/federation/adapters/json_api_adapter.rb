# JSON:API protocol adapter for Komunitin compatibility.
#
# Handles serialisation/deserialisation of JSON:API documents
# (application/vnd.api+json) and field mapping between Komunitin's
# accounting model and TimeOverflow's federation model.
#
# Amount conversions:
#   Komunitin uses "minor units" with a configurable scale (default 100 = centihours).
#   TimeOverflow uses seconds internally.
#   Outbound: seconds / 3600.0 * scale  (seconds -> centihours)
#   Inbound:  minor_units / scale.to_f * 3600  (centihours -> seconds)
#
# The scale is stored in partner.metadata["komunitin_scale"] (default 100).
#
module Federation
  module Adapters
    class JsonApiAdapter < BaseAdapter
      # Komunitin transfer state mapping (Komunitin -> TimeOverflow)
      INBOUND_STATE_MAP = {
        "new"       => "pending",
        "accepted"  => "pending",
        "committed" => "completed",
        "rejected"  => "cancelled",
        "deleted"   => "cancelled"
      }.freeze

      # TimeOverflow transfer state mapping (TimeOverflow -> Komunitin)
      OUTBOUND_STATE_MAP = {
        "pending"   => "new",
        "completed" => "committed",
        "cancelled" => "rejected",
        "failed"    => "rejected"
      }.freeze

      # Komunitin webhook event mapping (Komunitin -> TimeOverflow)
      WEBHOOK_EVENT_MAP = {
        "transfer.new"       => "transaction.created",
        "transfer.accepted"  => "transaction.updated",
        "transfer.committed" => "transaction.completed",
        "transfer.rejected"  => "transaction.cancelled",
        "transfer.deleted"   => "transaction.cancelled",
        "account.created"    => "member.created",
        "account.updated"    => "member.updated"
      }.freeze

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
        when "messages"           then "/messages" # Not in Komunitin spec -- custom extension
        else "/#{action}"
        end
      end

      def extra_headers
        { "Accept" => "application/vnd.api+json", "Content-Type" => "application/vnd.api+json" }
      end

      # --- Outbound transformation (TO seconds -> Komunitin minor units) ---

      def transform_outbound_transfer(payload)
        payload = payload.dup
        amount_seconds = payload.delete(:amount) || payload.delete("amount") || 0
        minor_units = seconds_to_minor_units(amount_seconds)

        payer_id = payload.delete(:source_account_id) || payload.delete("source_account_id")
        payee_id = payload.delete(:destination_account_id) || payload.delete("destination_account_id")
        state = payload.delete(:state) || payload.delete("state")
        description = payload.delete(:description) || payload.delete("description") || ""
        transfer_id = payload.delete(:id) || payload.delete("id")

        attributes = {
          amount: minor_units,
          meta: description,
          state: OUTBOUND_STATE_MAP[state.to_s] || "new"
        }

        relationships = {}
        if payer_id
          relationships[:payer] = { data: { type: "accounts", id: payer_id.to_s } }
        end
        if payee_id
          relationships[:payee] = { data: { type: "accounts", id: payee_id.to_s } }
        end

        JsonApiSerializer.serialize_resource(
          "transfers",
          transfer_id || SecureRandom.uuid,
          attributes,
          relationships: relationships
        )
      end

      def transform_outbound_message(payload)
        payload = payload.dup
        message_id = payload.delete(:id) || payload.delete("id")

        JsonApiSerializer.serialize_resource(
          "messages",
          message_id || SecureRandom.uuid,
          payload
        )
      end

      # --- Inbound transformation (Komunitin -> TO format) ---

      def transform_inbound_member(data)
        flat = JsonApiSerializer.deserialize(wrap_if_raw(data))
        return data unless flat.is_a?(Hash)

        {
          "id"       => flat["id"],
          "username" => flat["code"] || flat["id"],
          "balance"  => minor_units_to_seconds(flat["balance"].to_i),
          "name"     => flat["name"] || flat["code"] || "",
          "email"    => flat["email"],
          "active"   => flat["active"].nil? ? true : flat["active"]
        }.compact
      end

      def transform_inbound_members(data)
        flat = JsonApiSerializer.deserialize(wrap_if_raw(data))
        return data unless flat.is_a?(Array)

        flat.map do |member|
          {
            "id"       => member["id"],
            "username" => member["code"] || member["id"],
            "balance"  => minor_units_to_seconds(member["balance"].to_i),
            "name"     => member["name"] || member["code"] || "",
            "email"    => member["email"],
            "active"   => member["active"].nil? ? true : member["active"]
          }.compact
        end
      end

      def transform_inbound_listing(data)
        # Komunitin has no native listings concept; pass through.
        data
      end

      def transform_inbound_listings(data)
        # Komunitin has no native listings concept; pass through.
        data
      end

      def transform_inbound_transfer(data)
        flat = JsonApiSerializer.deserialize(wrap_if_raw(data))
        return data unless flat.is_a?(Hash)

        {
          "id"                     => flat["id"],
          "amount"                 => minor_units_to_seconds(flat["amount"].to_i),
          "description"            => flat["meta"] || flat["description"] || "",
          "state"                  => INBOUND_STATE_MAP[flat["state"].to_s] || flat["state"],
          "source_account_id"      => flat["payer_id"],
          "destination_account_id" => flat["payee_id"],
          "created_at"             => flat["created"] || flat["created_at"],
          "updated_at"             => flat["updated"] || flat["updated_at"]
        }.compact
      end

      # --- Webhook normalisation ---

      def normalize_webhook_event(event)
        WEBHOOK_EVENT_MAP[event.to_s] || event
      end

      def normalize_webhook_payload(payload)
        return payload unless payload.is_a?(Hash)

        # Komunitin webhooks wrap the resource in a JSON:API document
        flat = JsonApiSerializer.deserialize(payload)
        type = if flat.is_a?(Hash)
                 flat["type"]
               elsif flat.is_a?(Array) && flat.first
                 flat.first["type"]
               end

        case type
        when "transfers"
          if flat.is_a?(Hash)
            transform_inbound_transfer({ "data" => { "type" => "transfers", "id" => flat["id"], "attributes" => flat } })
          else
            flat.map { |t| transform_inbound_transfer({ "data" => { "type" => "transfers", "id" => t["id"], "attributes" => t } }) }
          end
        when "accounts"
          if flat.is_a?(Hash)
            transform_inbound_member({ "data" => { "type" => "accounts", "id" => flat["id"], "attributes" => flat } })
          else
            transform_inbound_members(flat.map { |m| { "type" => "accounts", "id" => m["id"], "attributes" => m } })
          end
        else
          flat
        end
      end

      # --- Response handling ---

      def unwrap_response(response)
        # JSON:API envelope: { "data" => [...] } or { "data" => { ... } }
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
        type = resource_type || "resources"

        if data.is_a?(Array)
          items = data.map { |item| item.is_a?(Hash) ? item.dup : { value: item } }
          JsonApiSerializer.serialize_collection(type, items, meta: meta)
        elsif data.is_a?(Hash)
          attrs = data.dup
          id = attrs.delete(:id) || attrs.delete("id")
          JsonApiSerializer.serialize_resource(type, id || "0", attrs)
            .merge(meta: meta)
        else
          JsonApiSerializer.serialize_resource(type, "0", { value: data })
            .merge(meta: meta)
        end
      end

      def serialize_error(message, status: nil, errors: nil)
        primary = JsonApiSerializer.serialize_error(
          title: "Error",
          detail: message,
          status: status || "422"
        )

        if errors.present?
          extra = errors.map do |e|
            detail = e.is_a?(Hash) ? (e[:detail] || e[:code] || e.to_s) : e.to_s
            { status: (status || "422").to_s, detail: detail }
          end
          primary[:errors].concat(extra)
        end

        primary
      end

      private

      # Minor-unit scale for the partner's Komunitin currency.
      # Default 100 = centihours.
      def komunitin_scale
        (@partner&.metadata&.dig("komunitin_scale") || 100).to_i
      end

      # Convert TimeOverflow seconds to Komunitin minor units (centihours).
      def seconds_to_minor_units(seconds)
        (seconds.to_f / 3600.0 * komunitin_scale).round
      end

      # Convert Komunitin minor units (centihours) to TimeOverflow seconds.
      def minor_units_to_seconds(minor_units)
        (minor_units.to_f / komunitin_scale.to_f * 3600).round
      end

      # Wrap raw data in a JSON:API document if it isn't already one.
      # Allows transform methods to accept either a full document or raw attributes.
      def wrap_if_raw(data)
        if data.is_a?(Hash) && (data.key?("data") || data.key?(:data))
          data
        elsif data.is_a?(Hash) && (data.key?("attributes") || data.key?(:attributes))
          { "data" => data }
        else
          data
        end
      end
    end
  end
end

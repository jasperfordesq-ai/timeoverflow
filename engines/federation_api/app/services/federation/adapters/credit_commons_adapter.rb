# Credit Commons protocol adapter.
#
# Handles the Credit Commons recursive mutual credit protocol:
#   - Hierarchical node tree with account paths (node/username)
#   - Transaction state machine (P→V→C→E→X)
#   - Double-entry entries (payer/payee/quant)
#   - Hashchain verification (Last-hash header)
#   - Multi-hop relay (POST /transaction/relay)
#
# Phase 2 implementation — stub for now. Full implementation will follow
# after CEN agrees on the protocol details.
#
module Federation
  module Adapters
    class CreditCommonsAdapter < BaseAdapter
      # CC transaction states
      STATES = { "P" => "pending", "V" => "pending", "C" => "completed", "E" => "cancelled", "X" => "cancelled" }.freeze
      REVERSE_STATES = { "pending" => "P", "completed" => "C", "cancelled" => "E" }.freeze

      # Valid CC state transitions
      VALID_TRANSITIONS = {
        "P" => %w[V C E],
        "V" => %w[C E],
        "C" => %w[E],
        "E" => %w[X],
        "X" => []
      }.freeze

      def protocol_name
        "Credit Commons"
      end

      def default_api_path
        ""
      end

      def content_type
        "application/json"
      end

      # --- Endpoint mapping (CC paths) ---

      def map_endpoint(action, params = {})
        case action.to_s
        when "members", "accounts" then "/accounts"
        when "member", "account"   then "/account/#{params[:id]}"
        when "transfers"           then "/transactions"
        when "transfer"            then "/transaction/#{params[:id]}"
        when "entries"             then "/entries"
        when "health", "about"     then "/about"
        when "relay"               then "/transaction/relay"
        when "forms"               then "/forms"
        else "/#{action}"
        end
      end

      # --- State machine helpers ---

      def valid_transition?(from_state, to_state)
        (VALID_TRANSITIONS[from_state] || []).include?(to_state)
      end

      def to_cc_state(to_status)
        REVERSE_STATES[to_status] || "P"
      end

      def from_cc_state(cc_state)
        STATES[cc_state] || "pending"
      end

      # --- Account path helpers ---

      def to_account_path(member)
        node_slug = @partner&.metadata&.dig("node_slug") || "timeoverflow"
        username = member.respond_to?(:member_uid) ? member.member_uid : member.to_s
        "#{node_slug}/#{username}"
      end

      def extract_username(path)
        path.to_s.split("/").last
      end

      # --- Stub implementations (Phase 2) ---

      def transform_outbound_transfer(payload)
        # TODO Phase 2: wrap as CC transaction with entries
        payload
      end

      def transform_outbound_message(payload)
        # CC doesn't have a native messaging endpoint
        payload
      end

      def transform_inbound_member(data)
        # TODO Phase 2: parse CC account format
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
        # TODO Phase 2: parse CC transaction + entries, convert state
        data
      end

      def unwrap_response(response)
        if response.is_a?(Hash) && response.key?("data")
          response["data"]
        else
          response
        end
      end

      def serialize_response(data, meta: {}, resource_type: nil)
        { data: data, meta: meta }
      end

      def serialize_error(message, status: nil, errors: nil)
        # CC error format: CCViolation / CCFailure
        { errors: [{ class: "CCViolation", message: message }] }
      end
    end
  end
end

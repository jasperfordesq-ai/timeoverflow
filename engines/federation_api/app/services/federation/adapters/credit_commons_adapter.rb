# Credit Commons protocol adapter.
#
# Handles the Credit Commons recursive mutual credit protocol:
#   - Hierarchical node tree with account paths (node/username)
#   - Transaction state machine (P->V->C->E->X)
#   - Double-entry entries (payer/payee/quant)
#   - Hashchain verification (Last-hash header)
#   - Multi-hop relay (POST /transaction/relay)
#
# Phase 2 implementation — full CC protocol support.
#
require "bigdecimal"

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

      # Default workflow code:
      #   + = payee side
      #   | = separator
      #   PPC-PE-CE= transitions
      DEFAULT_WORKFLOW = "+|PPC-PE-CE=".freeze

      # Default: 1 CC unit = 1 hour = 3600 seconds
      SECONDS_PER_UNIT = 3600

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
        node_slug = resolve_node_slug
        username = member.respond_to?(:member_uid) ? (member.member_uid || member.id.to_s) : member.to_s
        "#{node_slug}/#{username}"
      end

      def extract_username(path)
        path.to_s.split("/").last
      end

      # --- Amount conversion ---

      def to_cc_amount(seconds)
        rate = BigDecimal(exchange_rate.to_s)
        (BigDecimal(seconds.to_s) / 3600 * rate).round(4).to_f
      end

      def from_cc_amount(cc_units)
        rate = BigDecimal(exchange_rate.to_s)
        if rate <= 0
          Rails.logger.error("[Federation::CreditCommonsAdapter] Invalid exchange rate #{rate} — using 1.0")
          rate = BigDecimal("1.0")
        end
        (BigDecimal(cc_units.to_s) / rate * 3600).round.to_i
      end

      # --- Entry generation ---
      # Converts a FederationTransaction (with its associated Transfer + Movements)
      # into CC entry format: { payer, payee, quant, description }

      def generate_entries(txn)
        return [] unless txn

        node_slug = resolve_node_slug(txn.organization_id)
        entries = []

        if txn.transfer.present? && txn.transfer.respond_to?(:movements)
          # Build entries from the actual double-entry movements
          movements = txn.transfer.movements.order(:amount)
          debit_movement  = movements.detect { |m| m.amount.negative? }
          credit_movement = movements.detect { |m| m.amount.positive? }

          if movements.size != 2
            Rails.logger.error("[Federation::CreditCommonsAdapter] Expected 2 movements for transaction #{txn.id}, got #{movements.size}")
            return []
          end

          unless debit_movement && credit_movement
            Rails.logger.error("[Federation::CreditCommonsAdapter] Missing movements for transaction #{txn.id}: debit=#{debit_movement.present?}, credit=#{credit_movement.present?}")
            return []
          end

          payer_account = debit_movement.account
          payee_account = credit_movement.account

          payer_path = build_account_path(payer_account, node_slug, txn)
          payee_path = build_account_path(payee_account, node_slug, txn)

          entries << {
            payer: payer_path,
            payee: payee_path,
            quant: to_cc_amount(credit_movement.amount.abs),
            description: txn.transfer.respond_to?(:reason) ? txn.transfer.reason.to_s : "",
            uuid: txn.external_transaction_id || SecureRandom.uuid
          }
        else
          # No linked transfer — build a synthetic entry from the transaction record
          local_path = "#{node_slug}/#{txn.local_account_id}"
          remote_path = txn.remote_user_identifier.to_s

          if txn.outbound?
            payer_path = local_path
            payee_path = remote_path
          else
            payer_path = remote_path
            payee_path = local_path
          end

          entries << {
            payer: payer_path,
            payee: payee_path,
            quant: to_cc_amount(txn.amount),
            description: txn.metadata&.dig("reason").to_s,
            uuid: txn.external_transaction_id || SecureRandom.uuid
          }
        end

        entries
      end

      # --- Outbound transformation (TO Transfer -> CC Transaction) ---

      def transform_outbound_transfer(payload)
        # payload is expected to be a hash with TO transfer data
        txn = payload[:transaction] || payload["transaction"]

        uuid = txn&.external_transaction_id || SecureRandom.uuid
        state = txn ? to_cc_state(txn.status) : "P"

        entries = if txn
                    generate_entries(txn)
                  else
                    []
                  end

        {
          uuid: uuid,
          written: Time.current.iso8601,
          state: state,
          workflow: DEFAULT_WORKFLOW,
          entries: entries
        }
      end

      # Convert a FederationTransaction into CC transaction format
      def to_cc_transaction(txn)
        {
          uuid: txn.external_transaction_id || SecureRandom.uuid,
          written: (txn.created_at || Time.current).iso8601,
          state: to_cc_state(txn.status),
          workflow: DEFAULT_WORKFLOW,
          entries: generate_entries(txn)
        }
      end

      def transform_outbound_message(payload)
        # CC doesn't have a native messaging endpoint
        payload
      end

      # --- Inbound transformation (CC format -> TO format) ---

      def transform_inbound_transfer(data)
        data = data.with_indifferent_access if data.respond_to?(:with_indifferent_access)

        entries = data[:entries] || data["entries"] || []
        first_entry = entries.first || {}
        state = data[:state] || data["state"] || "P"

        unless STATES.key?(state)
          Rails.logger.warn("[Federation::CreditCommonsAdapter] Unknown CC state '#{state}' in inbound transfer #{data[:uuid] || data["uuid"]} — falling back to 'pending'")
        end

        # Validate state transition if we have an existing transaction for this UUID
        if (uuid = data[:uuid] || data["uuid"]).present?
          existing = FederationTransaction.find_by(external_transaction_id: uuid)
          if existing
            existing_cc_state = existing.metadata&.dig("cc_state") || REVERSE_STATES[existing.status] || "P"
            unless valid_transition?(existing_cc_state, state)
              Rails.logger.warn("[Federation::CreditCommonsAdapter] Invalid CC state transition #{existing_cc_state}→#{state} for transaction #{uuid} — rejecting")
              raise ArgumentError, "Invalid CC state transition from #{existing_cc_state} to #{state}"
            end
          end
        end

        {
          external_transaction_id: data[:uuid] || data["uuid"],
          status: from_cc_state(state),
          amount: from_cc_amount(first_entry[:quant] || first_entry["quant"] || 0),
          payer: first_entry[:payer] || first_entry["payer"],
          payee: first_entry[:payee] || first_entry["payee"],
          description: first_entry[:description] || first_entry["description"],
          remote_user_identifier: first_entry[:payer] || first_entry["payer"],
          cc_state: state,
          cc_workflow: data[:workflow] || data["workflow"] || DEFAULT_WORKFLOW
        }
      end

      # Parse a CC transaction from controller params into canonical format
      def parse_cc_transaction(params)
        data = params.respond_to?(:to_h) ? params.to_h : params
        transform_inbound_transfer(data)
      end

      def transform_inbound_member(data)
        data = data.with_indifferent_access if data.respond_to?(:with_indifferent_access)

        account_path = data[:id] || data["id"] || ""
        username = extract_username(account_path)

        {
          id: account_path,
          username: username,
          balance: from_cc_amount(data[:balance] || data["balance"] || 0),
          name: data[:name] || data["name"] || username,
          volume: from_cc_amount(data[:volume] || data["volume"] || 0),
          trades: data[:trades] || data["trades"] || 0
        }
      end

      def transform_inbound_members(data)
        Array(data).map { |d| transform_inbound_member(d) }
      end

      def transform_inbound_listing(data)
        data
      end

      def transform_inbound_listings(data)
        data
      end

      # --- About endpoint data ---

      def build_about_response(organization)
        config = FederationCcNodeConfig.for(organization)
        config.build_about_response
      end

      # --- Response handling ---

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

      def serialize_error(message, status: nil, errors: nil, meta: {})
        # CC error format: CCViolation / CCFailure — also include success: false
        # for consistency with REST adapter's error envelope.
        body = { success: false, error: message, errors: [{ class: "CCViolation", message: message }] }
        body[:field_errors] = errors if errors.present?
        body
      end

      # --- Hashchain verification ---
      # CC uses a chain of hashes to ensure transaction ordering integrity.
      # Each new transaction includes the hash of the previous one.

      def compute_hash(transaction_data, previous_hash)
        payload = "#{previous_hash}:#{canonical_json(transaction_data)}"
        Digest::SHA256.hexdigest(payload)
      end

      def canonical_json(data)
        JSON.generate(deep_sort_keys(data))
      end

      def deep_sort_keys(obj)
        case obj
        when Hash
          obj.sort.to_h.transform_values { |v| deep_sort_keys(v) }
        when Array
          obj.map { |v| deep_sort_keys(v) }
        else
          obj
        end
      end

      def last_hash
        @partner&.metadata&.dig("cc_last_hash") || Digest::SHA256.hexdigest("genesis")
      end

      def store_hash!(new_hash)
        return unless @partner
        @partner.with_lock do
          @partner.reload
          meta = (@partner.metadata || {}).merge("cc_last_hash" => new_hash)
          @partner.update!(metadata: meta)
        end
      end

      def verify_hashchain(inbound_hash, transaction_data)
        expected = compute_hash(transaction_data, last_hash)
        ActiveSupport::SecurityUtils.secure_compare(expected, inbound_hash.to_s)
      end

      # --- Extra headers for outbound requests ---

      def extra_headers
        { "Last-hash" => last_hash }
      end

      # --- Webhook event normalisation ---
      # CC uses different event names than TO — map them to canonical names.

      CC_EVENT_MAP = {
        "transaction.pending"   => "transaction.created",
        "transaction.validated" => "transaction.validated",
        "transaction.completed" => "transaction.completed",
        "transaction.erased"    => "transaction.cancelled",
        "transaction.expired"   => "transaction.cancelled",
        "account.created"       => "member.created",
        "account.updated"       => "member.updated"
      }.freeze

      def normalize_webhook_event(event)
        CC_EVENT_MAP[event.to_s] || event
      end

      def normalize_webhook_payload(payload)
        payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)

        if payload[:entries].present? || payload[:uuid].present?
          # This looks like a CC transaction payload — transform it
          { "transaction" => transform_inbound_transfer(payload) }
        else
          payload
        end
      end

      private

      def resolve_node_slug(org_id = nil)
        @_slug_cache ||= {}
        cache_key = org_id || :default

        @_slug_cache[cache_key] ||= begin
          if org_id
            config = FederationCcNodeConfig.find_by(organization_id: org_id)
            config&.node_slug || @partner&.metadata&.dig("node_slug") || "timeoverflow"
          else
            @partner&.metadata&.dig("node_slug") || "timeoverflow"
          end
        end
      end

      def exchange_rate
        rate = @partner&.metadata&.dig("cc_exchange_rate")
        rate = rate.to_f if rate
        (rate && rate > 0) ? rate : 1.0
      end

      def build_account_path(account, node_slug, txn)
        if account
          # Account belongs_to :accountable (polymorphic) — use the association
          # rather than querying Member by account_id (Members don't have that column).
          member = account.respond_to?(:accountable) ? account.accountable : nil
          member = nil unless member.is_a?(Member) rescue nil
          if member
            "#{node_slug}/#{member.member_uid || member.id}"
          else
            # Could be the remote side — use the remote identifier
            Rails.logger.warn("[Federation::CreditCommonsAdapter] No member found for account #{account.id} in transaction #{txn.id} — falling back to remote_user_identifier")
            txn.remote_user_identifier.to_s
          end
        else
          txn.remote_user_identifier.to_s
        end
      end
    end
  end
end

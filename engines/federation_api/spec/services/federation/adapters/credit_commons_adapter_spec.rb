require "rails_helper"

RSpec.describe Federation::Adapters::CreditCommonsAdapter do
  let!(:partner) { Fabricate(:federation_partner) }
  let(:adapter) { described_class.new(partner: partner) }

  before do
    partner.update_columns(protocol_type: "credit_commons")
  end

  describe "#protocol_name" do
    it { expect(adapter.protocol_name).to eq("Credit Commons") }
  end

  describe "#map_endpoint" do
    it "maps accounts to /accounts" do
      expect(adapter.map_endpoint("accounts")).to eq("/accounts")
    end

    it "maps transfers to /transactions" do
      expect(adapter.map_endpoint("transfers")).to eq("/transactions")
    end

    it "maps entries to /entries" do
      expect(adapter.map_endpoint("entries")).to eq("/entries")
    end
  end

  describe "state machine" do
    describe "#valid_transition?" do
      it "allows P → V (pending to validated)" do
        expect(adapter.valid_transition?("P", "V")).to be true
      end

      it "allows P → C (pending to completed)" do
        expect(adapter.valid_transition?("P", "C")).to be true
      end

      it "allows V → C (validated to completed)" do
        expect(adapter.valid_transition?("V", "C")).to be true
      end

      it "allows C → E (completed to erased)" do
        expect(adapter.valid_transition?("C", "E")).to be true
      end

      it "disallows E → P (erased to pending)" do
        expect(adapter.valid_transition?("E", "P")).to be false
      end

      it "disallows X → anything" do
        expect(adapter.valid_transition?("X", "P")).to be false
        expect(adapter.valid_transition?("X", "V")).to be false
        expect(adapter.valid_transition?("X", "C")).to be false
      end

      it "disallows C → P (completed to pending)" do
        expect(adapter.valid_transition?("C", "P")).to be false
      end
    end
  end

  describe "state mapping" do
    it "maps to CC state" do
      expect(adapter.to_cc_state("pending")).to eq("P")
      expect(adapter.to_cc_state("completed")).to eq("C")
      expect(adapter.to_cc_state("cancelled")).to eq("E")
    end

    it "maps from CC state" do
      expect(adapter.from_cc_state("P")).to eq("pending")
      expect(adapter.from_cc_state("V")).to eq("pending")
      expect(adapter.from_cc_state("C")).to eq("completed")
      expect(adapter.from_cc_state("E")).to eq("cancelled")
      expect(adapter.from_cc_state("X")).to eq("cancelled")
    end

    it "round-trips state mapping for supported states" do
      # Only states in REVERSE_STATES round-trip cleanly
      %w[pending completed cancelled].each do |state|
        expect(adapter.from_cc_state(adapter.to_cc_state(state))).to eq(state)
      end
    end
  end

  describe "#to_account_path" do
    it "builds node_slug/username format from a member object" do
      # resolve_node_slug falls back to partner.metadata["node_slug"] or "timeoverflow"
      partner.update!(metadata: (partner.metadata || {}).merge("node_slug" => "mynode"))
      member = double("Member", member_uid: "alice", id: 1)
      expect(adapter.to_account_path(member)).to eq("mynode/alice")
    end

    it "uses 'timeoverflow' as default node slug" do
      member = double("Member", member_uid: "bob", id: 2)
      expect(adapter.to_account_path(member)).to eq("timeoverflow/bob")
    end

    it "falls back to member.id when member_uid is nil" do
      member = double("Member", member_uid: nil, id: 99)
      expect(adapter.to_account_path(member)).to eq("timeoverflow/99")
    end

    it "handles a plain string argument" do
      expect(adapter.to_account_path("alice")).to eq("timeoverflow/alice")
    end
  end

  describe "#extract_username" do
    it "extracts last segment from path" do
      expect(adapter.extract_username("mynode/alice")).to eq("alice")
    end

    it "handles multi-segment paths" do
      expect(adapter.extract_username("root/node/alice")).to eq("alice")
    end
  end

  describe "amount conversion" do
    it "converts 3600 seconds to 1.0 CC amount" do
      expect(adapter.to_cc_amount(3600)).to eq(1.0)
    end

    it "converts 1.0 CC amount to 3600 seconds" do
      expect(adapter.from_cc_amount(1.0)).to eq(3600)
    end

    it "converts 1800 seconds to 0.5 CC amount" do
      expect(adapter.to_cc_amount(1800)).to eq(0.5)
    end

    it "converts 0.5 CC amount to 1800 seconds" do
      expect(adapter.from_cc_amount(0.5)).to eq(1800)
    end
  end

  describe "#generate_entries" do
    it "returns valid CC entry format from a FederationTransaction (no transfer)" do
      txn = double("FederationTransaction",
        transfer: nil,
        organization_id: nil,
        local_account_id: 42,
        remote_user_identifier: "node/bob",
        external_transaction_id: "uuid-123",
        amount: 3600,
        outbound?: true,
        metadata: { "reason" => "Test service" }
      )

      partner.update!(metadata: (partner.metadata || {}).merge("node_slug" => "node"))

      entries = adapter.generate_entries(txn)
      expect(entries).to be_an(Array)
      expect(entries.length).to eq(1)

      entry = entries.first
      expect(entry[:payer]).to eq("node/42")
      expect(entry[:payee]).to eq("node/bob")
      expect(entry[:quant]).to eq(1.0)
      expect(entry[:description]).to eq("Test service")
      expect(entry[:uuid]).to eq("uuid-123")
    end

    it "returns empty array for nil input" do
      expect(adapter.generate_entries(nil)).to eq([])
    end
  end
end

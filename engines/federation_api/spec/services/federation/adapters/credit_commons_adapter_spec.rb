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

    it "maps transaction to /transaction" do
      expect(adapter.map_endpoint("transaction")).to eq("/transaction")
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
      expect(adapter.to_cc_state("validated")).to eq("V")
      expect(adapter.to_cc_state("completed")).to eq("C")
      expect(adapter.to_cc_state("erased")).to eq("E")
    end

    it "maps from CC state" do
      expect(adapter.from_cc_state("P")).to eq("pending")
      expect(adapter.from_cc_state("V")).to eq("validated")
      expect(adapter.from_cc_state("C")).to eq("completed")
      expect(adapter.from_cc_state("E")).to eq("erased")
    end

    it "round-trips state mapping" do
      %w[pending validated completed erased].each do |state|
        expect(adapter.from_cc_state(adapter.to_cc_state(state))).to eq(state)
      end
    end
  end

  describe "#to_account_path" do
    it "builds node/username format" do
      expect(adapter.to_account_path("mynode", "alice")).to eq("mynode/alice")
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
    it "returns valid CC entry format with payer/payee/quant" do
      entries = adapter.generate_entries(
        payer: "node/alice",
        payee: "node/bob",
        quant: 1.0,
        description: "Test service"
      )
      expect(entries).to be_an(Array)
      expect(entries.length).to be >= 1

      entry = entries.first
      expect(entry[:payer]).to eq("node/alice")
      expect(entry[:payee]).to eq("node/bob")
      expect(entry[:quant]).to eq(1.0)
      expect(entry[:description]).to eq("Test service")
    end
  end
end

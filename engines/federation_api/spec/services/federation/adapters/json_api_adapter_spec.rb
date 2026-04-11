require "rails_helper"

RSpec.describe Federation::Adapters::JsonApiAdapter do
  let!(:partner) { Fabricate(:federation_partner) }
  let(:adapter) { described_class.new(partner: partner) }

  before do
    partner.update_columns(protocol_type: "json_api")
  end

  describe "#protocol_name" do
    it { expect(adapter.protocol_name).to eq("JSON:API") }
  end

  describe "#content_type" do
    it { expect(adapter.content_type).to eq("application/vnd.api+json") }
  end

  describe "#map_endpoint" do
    before do
      partner.update!(metadata: (partner.metadata || {}).merge("currency_code" => "TESTBANK"))
    end

    it "maps accounts with currency_code from partner metadata" do
      expect(adapter.map_endpoint("accounts")).to eq("/TESTBANK/accounts")
    end

    it "maps transfers with currency_code from partner metadata" do
      expect(adapter.map_endpoint("transfers")).to eq("/TESTBANK/transfers")
    end

    it "maps members with currency_code from partner metadata" do
      expect(adapter.map_endpoint("members")).to eq("/TESTBANK/accounts")
    end
  end

  describe "#transform_outbound_transfer" do
    it "converts seconds to minor units in JSON:API document" do
      data = { "amount" => 3600 }
      result = adapter.transform_outbound_transfer(data)
      # Returns a JSON:API document: { data: { type: "transfers", id: ..., attributes: { amount: 100, ... } } }
      expect(result[:data][:attributes][:amount]).to eq(100)
    end

    it "converts 7200 seconds to 200 minor units in JSON:API document" do
      data = { "amount" => 7200 }
      result = adapter.transform_outbound_transfer(data)
      expect(result[:data][:attributes][:amount]).to eq(200)
    end
  end

  describe "#transform_inbound_transfer" do
    it "converts minor units to seconds" do
      # Wrap in JSON:API document format for deserialization
      data = {
        "data" => {
          "type" => "transfers", "id" => "t1",
          "attributes" => { "amount" => 100, "state" => "new" }
        }
      }
      result = adapter.transform_inbound_transfer(data)
      expect(result["amount"]).to eq(3600)
    end

    it "maps state 'new' to 'pending'" do
      data = {
        "data" => {
          "type" => "transfers", "id" => "t1",
          "attributes" => { "amount" => 100, "state" => "new" }
        }
      }
      result = adapter.transform_inbound_transfer(data)
      expect(result["state"]).to eq("pending")
    end

    it "maps state 'committed' to 'completed'" do
      data = {
        "data" => {
          "type" => "transfers", "id" => "t1",
          "attributes" => { "amount" => 100, "state" => "committed" }
        }
      }
      result = adapter.transform_inbound_transfer(data)
      expect(result["state"]).to eq("completed")
    end

    it "maps state 'rejected' to 'cancelled'" do
      data = {
        "data" => {
          "type" => "transfers", "id" => "t1",
          "attributes" => { "amount" => 100, "state" => "rejected" }
        }
      }
      result = adapter.transform_inbound_transfer(data)
      expect(result["state"]).to eq("cancelled")
    end
  end

  describe "#transform_inbound_member" do
    it "extracts from JSON:API format" do
      # The method calls wrap_if_raw, which wraps { "attributes" => ... } in { "data" => ... }
      data = {
        "type" => "members",
        "id" => "abc-123",
        "attributes" => { "name" => "Alice", "email" => "alice@example.com" }
      }
      result = adapter.transform_inbound_member(data)
      expect(result["id"]).to eq("abc-123")
      expect(result["name"]).to eq("Alice")
      expect(result["email"]).to eq("alice@example.com")
    end
  end

  describe "#unwrap_response" do
    it "handles JSON:API collection" do
      response = {
        "data" => [
          { "type" => "members", "id" => "1", "attributes" => { "name" => "Alice" } },
          { "type" => "members", "id" => "2", "attributes" => { "name" => "Bob" } }
        ],
        "meta" => { "total" => 2 }
      }
      result = adapter.unwrap_response(response)
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
    end

    it "handles JSON:API single resource" do
      response = {
        "data" => { "type" => "members", "id" => "1", "attributes" => { "name" => "Alice" } }
      }
      result = adapter.unwrap_response(response)
      expect(result).to be_a(Hash)
    end
  end

  describe "#serialize_response" do
    it "wraps as JSON:API document" do
      result = adapter.serialize_response({ id: 1, name: "Test" }, resource_type: "members")
      expect(result).to have_key(:data)
    end
  end

  describe "#serialize_error" do
    it "returns JSON:API error format" do
      result = adapter.serialize_error("Not found", status: 404)
      expect(result).to have_key(:errors)
      expect(result[:errors]).to be_an(Array)
      expect(result[:errors].first[:status]).to eq("404")
      expect(result[:errors].first[:detail]).to eq("Not found")
    end
  end

  describe "amount round-trip" do
    it "converts 3600 seconds → 100 minor units → 3600 seconds" do
      outbound = adapter.transform_outbound_transfer({ "amount" => 3600 })
      minor_units = outbound[:data][:attributes][:amount]
      expect(minor_units).to eq(100)

      inbound_doc = {
        "data" => {
          "type" => "transfers", "id" => "t1",
          "attributes" => { "amount" => minor_units, "state" => "new" }
        }
      }
      inbound = adapter.transform_inbound_transfer(inbound_doc)
      expect(inbound["amount"]).to eq(3600)
    end
  end
end

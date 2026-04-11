require "rails_helper"

RSpec.describe Federation::Adapters::JsonApiSerializer do
  let(:serializer) { described_class }

  describe ".serialize_resource" do
    it "wraps as { data: { type, id, attributes } }" do
      result = serializer.serialize_resource("members", "123", { name: "Alice", email: "alice@example.com" })
      expect(result[:data][:type]).to eq("members")
      expect(result[:data][:id]).to eq("123")
      expect(result[:data][:attributes][:name]).to eq("Alice")
      expect(result[:data][:attributes][:email]).to eq("alice@example.com")
    end
  end

  describe ".serialize_collection" do
    it "wraps array as { data: [{...}], meta: {} }" do
      items = [
        { type: "members", id: "1", attributes: { name: "Alice" } },
        { type: "members", id: "2", attributes: { name: "Bob" } }
      ]
      result = serializer.serialize_collection(items, meta: { total: 2 })
      expect(result[:data]).to be_an(Array)
      expect(result[:data].length).to eq(2)
      expect(result[:meta][:total]).to eq(2)
    end
  end

  describe ".serialize_error" do
    it "wraps as { errors: [{ status, title, detail }] }" do
      result = serializer.serialize_error(status: "404", title: "Not Found", detail: "Resource not found")
      expect(result[:errors]).to be_an(Array)
      expect(result[:errors].first[:status]).to eq("404")
      expect(result[:errors].first[:title]).to eq("Not Found")
      expect(result[:errors].first[:detail]).to eq("Resource not found")
    end
  end

  describe ".deserialize" do
    it "flattens single resource" do
      input = {
        "data" => {
          "type" => "members",
          "id" => "123",
          "attributes" => { "name" => "Alice", "email" => "alice@example.com" }
        }
      }
      result = serializer.deserialize(input)
      expect(result["id"]).to eq("123")
      expect(result["type"]).to eq("members")
      expect(result["name"]).to eq("Alice")
      expect(result["email"]).to eq("alice@example.com")
    end

    it "flattens collection" do
      input = {
        "data" => [
          { "type" => "members", "id" => "1", "attributes" => { "name" => "Alice" } },
          { "type" => "members", "id" => "2", "attributes" => { "name" => "Bob" } }
        ]
      }
      result = serializer.deserialize(input)
      expect(result).to be_an(Array)
      expect(result.length).to eq(2)
      expect(result.first["name"]).to eq("Alice")
      expect(result.last["name"]).to eq("Bob")
    end

    it "extracts relationship IDs" do
      input = {
        "data" => {
          "type" => "transfers",
          "id" => "t1",
          "attributes" => { "amount" => 100 },
          "relationships" => {
            "payer" => { "data" => { "type" => "accounts", "id" => "acc-1" } },
            "payee" => { "data" => { "type" => "accounts", "id" => "acc-2" } }
          }
        }
      }
      result = serializer.deserialize(input)
      expect(result["payer_id"]).to eq("acc-1")
      expect(result["payee_id"]).to eq("acc-2")
    end
  end

  describe "round-trip" do
    it "serialize then deserialize produces original data" do
      original = { name: "Alice", email: "alice@example.com" }
      serialized = serializer.serialize_resource("members", "123", original)

      # Convert to string keys to simulate JSON round-trip
      json_string = serialized.to_json
      parsed = JSON.parse(json_string)

      deserialized = serializer.deserialize(parsed)
      expect(deserialized["name"]).to eq("Alice")
      expect(deserialized["email"]).to eq("alice@example.com")
      expect(deserialized["id"]).to eq("123")
    end
  end
end

require "rails_helper"

RSpec.describe Api::V1::MembersController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let(:raw_key) { "to_fed_test_key_#{SecureRandom.hex(16)}" }
  let!(:api_key) do
    FederationApiKey.create!(
      name: "Test Key",
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      active: true,
      organization: organization,
      permissions: { "profiles" => true }
    )
  end

  before do
    request.headers["X-Federation-Api-Key"] = raw_key
  end

  describe "GET #index" do
    it "returns active members for the organization" do
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]).to be_an(Array)
      expect(body["data"].length).to eq(1)
      expect(body["data"].first["member_uid"]).to eq(member.member_uid)
    end

    it "filters by search query" do
      get :index, params: {
        organization_id: organization.id,
        search: member.user.username
      }

      body = JSON.parse(response.body)
      expect(body["data"].length).to eq(1)
    end

    it "does not return inactive members" do
      member.update!(active: false)

      get :index, params: { organization_id: organization.id }

      body = JSON.parse(response.body)
      expect(body["data"]).to be_empty
    end
  end

  describe "GET #show" do
    it "returns member details" do
      get :show, params: { id: member.id, organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["id"]).to eq(member.id)
      expect(body["data"]["email"]).to eq(member.user.email)
    end
  end
end

require "rails_helper"

RSpec.describe Api::V1::OrganizationsController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let(:raw_key) { "to_fed_test_key_#{SecureRandom.hex(16)}" }
  let!(:api_key) do
    FederationApiKey.create!(
      name: "Test Key",
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      active: true
    )
  end

  before do
    request.headers["X-Federation-Api-Key"] = raw_key
  end

  describe "GET #index" do
    it "returns a list of organizations" do
      get :index

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]).to be_an(Array)
      org_names = body["data"].map { |o| o["name"] }
      expect(org_names).to include(organization.name)
    end

    it "returns unauthorized without API key" do
      request.headers["X-Federation-Api-Key"] = nil
      get :index

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns unauthorized with invalid API key" do
      request.headers["X-Federation-Api-Key"] = "invalid_key"
      get :index

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns pagination metadata" do
      get :index

      body = JSON.parse(response.body)
      expect(body["meta"]).to include("current_page", "total_pages", "total_count", "per_page")
    end
  end

  describe "GET #show" do
    it "returns organization details" do
      get :show, params: { id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["id"]).to eq(organization.id)
      expect(body["data"]["name"]).to eq(organization.name)
    end

    it "returns 404 for non-existent organization" do
      get :show, params: { id: 999999 }

      expect(response).to have_http_status(:not_found)
    end
  end
end

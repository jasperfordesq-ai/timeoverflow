require "rails_helper"

RSpec.describe Api::V1::OffersController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let!(:category) { Fabricate(:category) }
  let!(:offer) do
    Fabricate(:offer,
      user: member.user,
      organization: organization,
      category: category,
      active: true
    )
  end
  let(:raw_key) { "to_fed_test_key_#{SecureRandom.hex(16)}" }
  let!(:api_key) do
    FederationApiKey.create!(
      name: "Test Key",
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      active: true,
      organization: organization,
      permissions: { "listings" => true }
    )
  end

  before do
    request.headers["X-Federation-Api-Key"] = raw_key
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
    # Member must be opted in for their offers to be visible via federation
    FederationMemberPreference.for(member).update!(opted_in: true)
  end

  describe "GET #index" do
    it "returns active offers for the organization" do
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]).to be_an(Array)
      expect(body["data"].first["type"]).to eq("offer")
    end

    it "filters by category" do
      get :index, params: {
        organization_id: organization.id,
        category_id: category.id
      }

      body = JSON.parse(response.body)
      expect(body["data"].length).to be >= 1
    end
  end

  describe "GET #show" do
    it "returns offer details with description" do
      get :show, params: { id: offer.id, organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["id"]).to eq(offer.id)
      expect(body["data"]).to have_key("description")
    end
  end
end

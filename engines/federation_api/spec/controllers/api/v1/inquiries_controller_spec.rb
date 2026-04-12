require "rails_helper"

RSpec.describe Api::V1::InquiriesController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let!(:other_member) { Fabricate(:member, organization: organization) }
  let!(:category) { Fabricate(:category) }
  let!(:inquiry) do
    Fabricate(:inquiry,
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
    FederationMemberPreference.for(member).update!(opted_in: true)
  end

  # --- Authentication & authorization ---

  describe "authentication" do
    it "rejects requests without an API key" do
      request.headers["X-Federation-Api-Key"] = nil
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
    end

    it "rejects requests with an invalid API key" do
      request.headers["X-Federation-Api-Key"] = "invalid_key_123"
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects requests without the listings permission" do
      api_key.update!(permissions: { "profiles" => true })
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:forbidden)
    end
  end

  # --- Organization scoping ---

  describe "organization scoping" do
    it "requires organization_id parameter" do
      get :index
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects requests for orgs with federation disabled" do
      FederationOrganizationSetting.for(organization).update!(federation_enabled: false)
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:forbidden)
    end

    it "does not show inquiries from other organizations" do
      other_org = Fabricate(:organization)
      other_org_member = Fabricate(:member, organization: other_org)
      FederationMemberPreference.for(other_org_member).update!(opted_in: true)
      Fabricate(:inquiry, user: other_org_member.user, organization: other_org, active: true)

      get :index, params: { organization_id: organization.id }
      body = JSON.parse(response.body)
      org_ids = body["data"].map { |i| i["organization_id"] }.uniq
      expect(org_ids).to eq([organization.id])
    end
  end

  # --- GET #index ---

  describe "GET #index" do
    it "returns active inquiries for the organization" do
      get :index, params: { organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]).to be_an(Array)
      expect(body["data"].first["type"]).to eq("inquiry")
      expect(body["meta"]).to be_a(Hash)
    end

    it "only shows inquiries from opted-in members" do
      # other_member has NOT opted in
      Fabricate(:inquiry, user: other_member.user, organization: organization, active: true)

      get :index, params: { organization_id: organization.id }
      body = JSON.parse(response.body)
      user_ids = body["data"].map { |i| i["user_id"] }
      expect(user_ids).not_to include(other_member.user_id)
    end

    it "filters by category_id" do
      other_category = Fabricate(:category)
      Fabricate(:inquiry, user: member.user, organization: organization,
                category: other_category, active: true)

      get :index, params: { organization_id: organization.id, category_id: category.id }
      body = JSON.parse(response.body)
      category_ids = body["data"].map { |i| i["category_id"] }.uniq
      expect(category_ids).to eq([category.id])
    end

    it "supports pagination" do
      get :index, params: { organization_id: organization.id, page: 1, per_page: 1 }

      body = JSON.parse(response.body)
      expect(body["meta"]["per_page"]).to eq(1)
      expect(body["meta"]["current_page"]).to eq(1)
    end

    it "returns correct response envelope format" do
      get :index, params: { organization_id: organization.id }

      body = JSON.parse(response.body)
      expect(body).to have_key("success")
      expect(body).to have_key("data")
      expect(body).to have_key("meta")
    end
  end

  # --- GET #show ---

  describe "GET #show" do
    it "returns inquiry details with description" do
      get :show, params: { id: inquiry.id, organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["id"]).to eq(inquiry.id)
      expect(body["data"]["type"]).to eq("inquiry")
      expect(body["data"]).to have_key("description")
      expect(body["data"]).to have_key("username")
    end

    it "returns 404 for non-existent inquiry" do
      get :show, params: { id: 999999, organization_id: organization.id }

      expect(response).to have_http_status(:not_found)
    end

    it "returns 404 for inquiry from another organization" do
      other_org = Fabricate(:organization)
      other_org_member = Fabricate(:member, organization: other_org)
      other_inquiry = Fabricate(:inquiry, user: other_org_member.user,
                                organization: other_org, active: true)

      get :show, params: { id: other_inquiry.id, organization_id: organization.id }
      expect(response).to have_http_status(:not_found)
    end
  end
end

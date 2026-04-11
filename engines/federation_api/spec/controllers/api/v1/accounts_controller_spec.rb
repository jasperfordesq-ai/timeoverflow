require "rails_helper"

RSpec.describe Api::V1::AccountsController, type: :controller do
  let!(:organization) { Fabricate(:organization) }
  let!(:member) { Fabricate(:member, organization: organization) }
  let(:raw_key) { "to_fed_test_key_#{SecureRandom.hex(16)}" }
  let!(:api_key) do
    FederationApiKey.create!(
      name: "Test Key",
      key_hash: Digest::SHA256.hexdigest(raw_key),
      key_prefix: raw_key[0..7],
      active: true,
      permissions: { "transactions" => true }
    )
  end

  before do
    request.headers["X-Federation-Api-Key"] = raw_key
    FederationOrganizationSetting.for(organization).update!(federation_enabled: true)
  end

  describe "GET #show" do
    it "returns account balance and details" do
      get :show, params: { id: member.account.id }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["id"]).to eq(member.account.id)
      expect(body["data"]).to have_key("balance")
      expect(body["data"]).to have_key("movements")
    end

    it "returns 404 for non-existent account" do
      get :show, params: { id: 999999 }

      expect(response).to have_http_status(:not_found)
    end
  end
end

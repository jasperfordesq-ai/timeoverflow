require "rails_helper"

RSpec.describe Api::V1::HealthController, type: :controller do
  describe "GET #show" do
    # The health controller performs a write+read cycle against Rails.cache.
    # In test environments the default cache store is :null_store which never
    # returns written values, causing the cache check to report "error" even
    # when nothing is actually wrong.  Stub the pair so the "happy-path"
    # tests see a working cache.
    before do
      allow(Rails.cache).to receive(:write).and_return(true)
      allow(Rails.cache).to receive(:read).and_return("1")
    end

    it "returns 200 with healthy status and no auth required" do
      get :show

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["success"]).to be true
      expect(body["data"]["status"]).to eq("healthy")
    end

    it "returns platform, version, and timestamp" do
      get :show

      body = JSON.parse(response.body)
      expect(body["data"]["platform"]).to eq("timeoverflow")
      expect(body["data"]["version"]).to eq(FederationApi::VERSION)
      expect(body["data"]["version"]).to be_present
      expect(body["data"]["timestamp"]).to be_present
    end

    it "returns database: ok, cache: ok, federation_api: ok" do
      get :show

      body = JSON.parse(response.body)
      checks = body["data"]["checks"]
      expect(checks["database"]).to eq("ok")
      expect(checks["cache"]).to eq("ok")
      expect(checks["federation_api"]).to eq("ok")
    end

    it "returns organizations_count and federation_partners_count" do
      Fabricate(:organization)
      Fabricate(:federation_partner, status: "active")

      get :show

      body = JSON.parse(response.body)
      expect(body["data"]["organizations_count"]).to be >= 1
      expect(body["data"]["federation_partners_count"]).to be >= 1
    end

    it "returns 503 when database is down" do
      allow(ActiveRecord::Base.connection).to receive(:select_value).and_raise(ActiveRecord::ConnectionNotEstablished)

      get :show

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
      expect(body["data"]["status"]).to eq("unhealthy")
      expect(body["data"]["checks"]["database"]).to eq("error")
    end

    it "returns 503 when cache is down" do
      # Override the default stubs to simulate a cache failure.
      # Use RuntimeError instead of Redis::CannotConnectError which may not
      # be defined in all test environments.
      allow(Rails.cache).to receive(:write).and_raise(RuntimeError.new("Connection refused"))

      get :show

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["success"]).to be false
      expect(body["data"]["status"]).to eq("unhealthy")
      expect(body["data"]["checks"]["cache"]).to eq("error")
    end

    it "does NOT require an API key" do
      # No X-Federation-Api-Key header set
      get :show

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["data"]["status"]).to eq("healthy")
    end
  end
end

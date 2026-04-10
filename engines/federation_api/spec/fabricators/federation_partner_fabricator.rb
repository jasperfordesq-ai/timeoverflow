Fabricator(:federation_partner) do
  name { "Test Nexus Tenant" }
  platform_type "nexus"
  api_endpoint { "https://api.test-nexus.example.com" }
  webhook_url { "https://api.test-nexus.example.com/webhooks/receive" }
  webhook_secret { SecureRandom.hex(32) }
  status "active"
  partnership_level 3
  feature_gates do
    {
      "profiles_enabled" => true,
      "listings_enabled" => true,
      "transactions_enabled" => true,
      "messaging_enabled" => false
    }
  end
end

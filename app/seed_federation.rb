# Seed federation partner and ensure API key exists
partner = FederationPartner.find_or_create_by!(name: "Nexus Local") do |p|
  p.platform_type = "nexus"
  p.api_endpoint = "http://172.18.0.7:80"
  p.webhook_url = "http://172.18.0.7:80/api/v1/federation/webhooks/receive"
  p.webhook_secret = SecureRandom.hex(32)
  p.status = "active"
  p.partnership_level = 3
  p.feature_gates = {
    "profiles_enabled" => true,
    "listings_enabled" => true,
    "transactions_enabled" => true,
    "messaging_enabled" => false
  }
end
puts "Partner ID: #{partner.id}, Status: #{partner.status}, Level: #{partner.partnership_level}"

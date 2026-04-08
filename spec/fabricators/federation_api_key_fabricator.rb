Fabricator(:federation_api_key) do
  name { "Test API Key" }
  key_hash { Digest::SHA256.hexdigest("test_key_#{SecureRandom.hex(8)}") }
  key_prefix { "to_fed_t" }
  active true
  permissions { {} }
end

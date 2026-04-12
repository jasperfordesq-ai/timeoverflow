key, raw = FederationApiKey.generate!(name: "E2E Test Key", permissions: { "profiles" => true, "listings" => true, "transactions" => true })
puts raw

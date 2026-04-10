Fabricator(:federation_transaction) do
  federation_partner { Fabricate(:federation_partner) }
  direction "inbound"
  local_account_id { 1 }
  remote_user_identifier { "remote_user@nexus.example.com" }
  amount { 3600 }
  reason { "Federation test transfer" }
  status "pending"
end

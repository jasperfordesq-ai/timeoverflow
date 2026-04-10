Fabricator(:federation_message) do
  federation_partner { Fabricate(:federation_partner) }
  organization_id { 1 }
  local_member_id { 1 }
  remote_user_identifier { "remote_user@nexus.example.com" }
  direction "inbound"
  subject { "Test federation message" }
  body { "This is a test message body." }
  status "pending"
end

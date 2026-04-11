Fabricator(:federation_webhook_log) do
  federation_partner { Fabricate(:federation_partner) }
  event_type "transaction.requested"
  direction "outbound"
  status "pending"
end

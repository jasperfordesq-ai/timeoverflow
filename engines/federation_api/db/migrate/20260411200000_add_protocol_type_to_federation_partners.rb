# Add protocol_type to federation partners.
#
# Distinct from platform_type ("who are they" — nexus, timeoverflow, custom):
# protocol_type is "how do we talk to them" — rest, json_api, credit_commons.
#
# All existing partners default to "rest" (the current JSON envelope format).
# New partners can be configured with json_api (Komunitin) or credit_commons
# (Credit Commons protocol) via the admin panel.
#
class AddProtocolTypeToFederationPartners < ActiveRecord::Migration[7.2]
  def change
    add_column :federation_partners, :protocol_type, :string, null: false, default: "rest"
    add_index  :federation_partners, :protocol_type
  end
end

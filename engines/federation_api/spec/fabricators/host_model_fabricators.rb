# Fabricators for host app models used in federation specs.
# These provide test fixtures when the host app's spec/fabricators/ directory
# is not available (e.g., in production Docker images).
#
# Note: No guard checks — these are loaded explicitly by rails_helper.rb
# after the federation fabricators. If the host app's fabricators are also
# loaded, Fabrication will raise on duplicate definition (which is correct —
# it means the host spec/ is available and these aren't needed).

begin
  Fabricator(:organization) do
    name { "Test Timebank #{SecureRandom.hex(4)}" }
  end
rescue Fabrication::DuplicateFabricatorError
  # Host app already defined this fabricator — skip
end

begin
  Fabricator(:user) do
    username { "user_#{SecureRandom.hex(4)}" }
    email { "user_#{SecureRandom.hex(4)}@example.com" }
    password { "password123" }
    password_confirmation { "password123" }
  end
rescue Fabrication::DuplicateFabricatorError
  # Host app already defined this fabricator — skip
end

begin
  Fabricator(:member) do
    user
    organization
  end
rescue Fabrication::DuplicateFabricatorError
  # Host app already defined this fabricator — skip
end

begin
  Fabricator(:category) do
    name { "Category #{SecureRandom.hex(4)}" }
  end
rescue Fabrication::DuplicateFabricatorError
  # Host app already defined this fabricator — skip
end

begin
  Fabricator(:offer) do
    user
    organization
    category
    title { "Offer #{SecureRandom.hex(4)}" }
    description { "Test offer description" }
  end
rescue Fabrication::DuplicateFabricatorError
  # Host app already defined this fabricator — skip
end

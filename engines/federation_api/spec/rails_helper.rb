# Engine spec helper.
#
# Boots the Rails application in test mode. Delegates to the host
# app's spec_helper if present, otherwise sets up a minimal test
# environment directly.
#
# This allows engine specs to use `require "rails_helper"` (standard
# convention) whether or not the host's spec/ directory is available
# (e.g. in production Docker images where spec/ is stripped).
#
host_spec_helper = File.expand_path("../../../spec/spec_helper", __dir__)

if File.exist?("#{host_spec_helper}.rb")
  require host_spec_helper
else
  # Minimal standalone boot — used when host spec/ is not available.
  ENV["RAILS_ENV"] ||= "test"
  ENV["ADMINS"] ||= "admin@timeoverflow.org"

  require File.expand_path("../../../config/environment", __dir__)
  require "rspec/rails"
  require "fabrication"

  # Silence Sidekiq logger in tests
  if defined?(Sidekiq)
    Sidekiq.configure_client { |c| c.logger = nil }
  end

  RSpec.configure do |config|
    config.use_transactional_fixtures = true
    config.infer_spec_type_from_file_location!
  end
end

# Additional configuration for engine specs
RSpec.configure do |config|
  # Ensure federation tables exist
  config.before(:suite) do
    ActiveRecord::Migration.maintain_test_schema!
  end

  # Force English locale for consistent validation messages in tests
  config.before(:each) do
    I18n.locale = :en
  end
end

# Register engine fabricators with Fabrication so `Fabricate(:federation_partner)`
# etc. work without needing the host app's spec/fabricators/ directory.
engine_fabricators = File.expand_path("fabricators", __dir__)
if Dir.exist?(engine_fabricators)
  Fabrication.configure do |c|
    c.path_prefix = [] unless c.path_prefix.is_a?(Array)
  end
  Dir[File.join(engine_fabricators, "**", "*_fabricator*.rb")].each { |f| require f }
end

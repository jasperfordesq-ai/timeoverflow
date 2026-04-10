# Engine spec helper — delegates to the host app's spec_helper.rb.
#
# This allows engine specs to use `require "rails_helper"` (standard convention)
# while actually loading the host app's test environment.
#
require_relative "../../../spec/spec_helper"

# Additional configuration for engine specs
RSpec.configure do |config|
  # Ensure federation tables exist
  config.before(:suite) do
    ActiveRecord::Migration.maintain_test_schema!
  end
end

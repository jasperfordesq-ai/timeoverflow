require_relative "lib/federation_api/version"

Gem::Specification.new do |spec|
  spec.name        = "federation_api"
  spec.version     = FederationApi::VERSION
  spec.authors     = ["Project NEXUS"]
  spec.homepage    = "https://github.com/jasperfordesq-ai/timeoverflow"
  spec.summary     = "Federation API engine for TimeOverflow"
  spec.description = "Self-contained Rails Engine that adds a JSON REST API layer " \
                     "to TimeOverflow, enabling cross-platform time exchanges with " \
                     "external timebanking partners (e.g., Project NEXUS)."
  spec.license     = "AGPL-3.0"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "LICENSE", "README.md"]
  end

  spec.required_ruby_version = ">= 3.0"

  # Only Rails itself — all other deps (sidekiq, pg, etc.) come from the host app.
  spec.add_dependency "rails", ">= 7.0"
end

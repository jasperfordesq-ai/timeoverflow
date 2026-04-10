# FederationApi Rails Engine
#
# Self-contained plug-in that adds cross-platform federation endpoints to
# TimeOverflow.  Touches ZERO original host files — all routes, config,
# migrations, queues, and cron schedules are registered dynamically.
#
# Activation:
#   1. Add `gem "federation_api", path: "engines/federation_api"` to Gemfile
#      (or use the Gemfile.federation overlay with BUNDLE_GEMFILE)
#   2. Set FEDERATION_ENABLED=true in the environment
#   3. Run `rake db:migrate` to create the federation_* tables
#
module FederationApi
  class Engine < ::Rails::Engine
    # ---------------------------------------------------------------
    # Non-isolated engine.
    #
    # Models keep their natural names (FederationPartner, not
    # FederationApi::FederationPartner) and controllers stay under
    # Api::V1:: to match the /api/v1/ URL structure.
    # ---------------------------------------------------------------

    # --- Federation configuration from ENV --------------------------
    initializer "federation_api.configuration", before: :load_config_initializers do |app|
      app.config.federation = ActiveSupport::OrderedOptions.new
      app.config.federation.enabled       = ENV.fetch("FEDERATION_ENABLED", "false") == "true"
      app.config.federation.webhook_timeout    = ENV.fetch("FEDERATION_WEBHOOK_TIMEOUT", "10").to_i
      app.config.federation.max_transfer_amount = ENV.fetch("FEDERATION_MAX_TRANSFER_AMOUNT", "0").to_i
      app.config.federation.rate_limit          = ENV.fetch("FEDERATION_RATE_LIMIT", "100").to_i
    end

    # --- Devise-i18n compatibility ----------------------------------
    # devise-i18n's Railtie calls `helper DeviseI18n::ViewHelpers` on
    # all controllers, but ActionController::API has no `helper`.
    # This no-op prevents the NoMethodError at boot.
    initializer "federation_api.api_controller_fix", before: :load_config_initializers do
      ActiveSupport.on_load :action_controller_api do
        def self.helper(*)
          # no-op for API controllers
        end
      end
    end

    # --- Auto-mount routes ------------------------------------------
    # Appends federation API routes to the host app without touching
    # config/routes.rb.  Routes are drawn AFTER the host's own routes,
    # so they cannot collide with existing paths.
    initializer "federation_api.routes", after: :add_routing_paths do |app|
      app.routes.append do
        namespace :api do
          namespace :v1 do
            # Nexus-compatible
            resources :listings, only: [:index, :show]
            get "health", to: "health#show"

            # Native TimeOverflow endpoints
            resources :organizations, only: [:index, :show]
            resources :members, only: [:index, :show]
            resources :offers, only: [:index, :show]
            resources :inquiries, only: [:index, :show]
            resources :transfers, only: [:create]
            resources :accounts, only: [:show]
            post "webhooks/receive", to: "webhooks#receive"
          end
        end
      end
    end

    # --- Migrations --------------------------------------------------
    # Append the engine's db/migrate to the host's migration paths so
    # `rake db:migrate` picks them up automatically.
    initializer "federation_api.append_migrations" do |app|
      unless app.root.to_s == root.to_s
        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end
    end

    # --- Sidekiq queue -----------------------------------------------
    # Register the :federation queue so the Sidekiq server processes
    # federation jobs.  Works with Sidekiq 6.x (host app uses ~> 6.5).
    initializer "federation_api.sidekiq_queue" do
      next unless defined?(Sidekiq)

      Sidekiq.configure_server do |config|
        # Sidekiq 6.x stores queues in Sidekiq.options[:queues]
        queues = Sidekiq.options[:queues] rescue nil
        if queues.is_a?(Array) && !queues.include?("federation")
          # Insert at position 0 so federation jobs have priority
          queues.unshift("federation")
        end
      end
    end

    # --- Sidekiq-cron schedule ----------------------------------------
    # Register the daily reconciliation job without touching schedule.yml.
    initializer "federation_api.cron_schedule" do
      next unless defined?(Sidekiq::Cron::Job)

      Rails.application.config.after_initialize do
        if ENV.fetch("FEDERATION_ENABLED", "false") == "true"
          Sidekiq::Cron::Job.create(
            name:  "federation_reconciliation",
            cron:  "0 3 * * *",  # daily at 3 AM
            class: "Federation::ReconciliationJob",
            queue: "federation"
          )
        end
      end
    end

    # --- Rake tasks ---------------------------------------------------
    rake_tasks do
      load root.join("lib", "tasks", "federation.rake")
    end
  end
end

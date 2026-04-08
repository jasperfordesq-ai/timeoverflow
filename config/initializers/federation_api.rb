# Federation API configuration.
#
# Configure via environment variables:
#
#   FEDERATION_ENABLED=true             # Enable/disable federation API
#   FEDERATION_DEFAULT_PARTNER_NAME=    # Default partner name for auto-registration
#   FEDERATION_WEBHOOK_TIMEOUT=10       # Webhook delivery timeout in seconds
#   FEDERATION_MAX_TRANSFER_AMOUNT=     # Maximum single transfer amount (seconds)
#   FEDERATION_RATE_LIMIT=100           # Max API requests per minute per key
#
Rails.application.config.federation = ActiveSupport::OrderedOptions.new
Rails.application.config.federation.enabled = ENV.fetch("FEDERATION_ENABLED", "false") == "true"
Rails.application.config.federation.webhook_timeout = ENV.fetch("FEDERATION_WEBHOOK_TIMEOUT", "10").to_i
Rails.application.config.federation.max_transfer_amount = ENV.fetch("FEDERATION_MAX_TRANSFER_AMOUNT", "0").to_i
Rails.application.config.federation.rate_limit = ENV.fetch("FEDERATION_RATE_LIMIT", "100").to_i

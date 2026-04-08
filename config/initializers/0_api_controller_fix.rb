# Fix devise-i18n compatibility with ActionController::API.
#
# devise-i18n's Railtie calls `helper DeviseI18n::ViewHelpers` via
# `ActiveSupport.on_load :action_controller`, which fires for both
# ActionController::Base and ActionController::API. But API controllers
# don't have the `helper` method, causing a NoMethodError at boot.
#
# This patch adds a no-op `helper` to ActionController::API so the
# railtie call succeeds silently.
#
# File named with 0_ prefix to load before other initializers.
#
ActiveSupport.on_load :action_controller_api do
  def self.helper(*)
    # no-op for API controllers
  end
end

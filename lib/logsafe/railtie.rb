# frozen_string_literal: true

module Logsafe
  # In development an app that sets no storage gets one, after its own initializers had their say.
  class Railtie < Rails::Railtie
    config.after_initialize do
      if Rails.env.development? && !Logsafe.storage? && Rails.logger.respond_to?(:broadcast_to)
        Development.start(Rails.root.join("tmp/logsafe"), Rails.logger)
      end
    end
  end
end

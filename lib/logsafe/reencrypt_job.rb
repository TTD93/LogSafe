# frozen_string_literal: true

require "active_job"

module Logsafe
  # Run once after the key was changed, with the old key in Logsafe.old_keys. See Logsafe.reencrypt.
  class ReencryptJob < ActiveJob::Base
    def perform
      Logsafe.reencrypt
    end
  end
end

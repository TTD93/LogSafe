# frozen_string_literal: true

require "active_job"

module Logsafe
  # Fails when no lines arrive any more, so that whatever reports your failed jobs reports this too.
  # Takes what Logsafe.check takes.
  class CheckJob < ActiveJob::Base
    def perform(*streams, **options)
      Logsafe.check(*streams, **options)
    end
  end
end

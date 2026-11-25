# frozen_string_literal: true

require "active_job"

module Logsafe
  # A plain Active Job, so whatever runs your jobs can run it: Solid Queue, Sidekiq, GoodJob, Resque, ...
  # Without arguments it merges every stream; with stream names, only those.
  class MergeJob < ActiveJob::Base
    def perform(*streams)
      Logsafe.merge(*streams)
    end
  end
end

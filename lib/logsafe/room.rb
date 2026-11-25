# frozen_string_literal: true

require "open3"

module Logsafe
  # There is too little room on the disk for what was asked. Never a reason to leave a part out.
  class Full < Error; end

  # How much of a day may be unpacked in a folder: a quarter of what is free there, because sorting
  # needs the lines up to three times, and what shares the disk must go on working.
  class Room
    SHARE = 4

    # The bytes free where this folder is. A great many when df does not say.
    def self.free(dir)
      report, = Open3.capture2("df", "-Pk", dir)
      report[/\s(-?\d+)\s+\d+%/, 1]&.to_i&.*(1024) || (1 << 62)
    end

    def initialize(dir)
      @left = Room.free(dir) / SHARE
      @lock = Mutex.new
    end

    # Called from several threads.
    def take(bytes)
      left = @lock.synchronize { @left -= bytes }
      raise Full, "there is too little room on the disk for this day's logs" if left.negative?
    end

    def left
      [@left, 1].max
    end
  end
end

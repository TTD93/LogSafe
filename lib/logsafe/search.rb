# frozen_string_literal: true

require "open3"

module Logsafe
  # Finds lines in the days asked for, in the copies of those days on this machine: see Copies.
  module Search
    LIMIT = 500
    WORDS = 8 # each word is one more pass over the lines
    LIST_FOR = 60 # seconds a listing of the storage is believed: parts come once a minute
    LEVELS = { "debug" => "debug", "info" => "info", "warn" => "warn|warning",
               "error" => "error", "fatal" => "fatal" }.freeze
    DAY_FILE = %r{\A\d{4}/\d{2}/([^/]+)\.(\d{4}-\d{2}-\d{2})\.log\.gz(\.enc)?\z}

    class << self
      # { [stream, day] => keys } for what the storage has of the days from..to (dates): each day's
      # file, and the parts that are not in it yet.
      def sources(from, to)
        months = (from..to).map { |date| date.strftime("%Y/%m/") }.uniq
        keys = months.flat_map { |month| listed(month) }.grep(DAY_FILE) + listed(PARTS)
        days = (from..to).map(&:to_s)
        keys.group_by { |key| stream_and_day(key) }.select { |(_, day), _| days.include?(day) }
      end

      # The last LIMIT lines that match, oldest first, as [stream, line], and then what could not be
      # read, as texts: one stream that fails does not hide the others. days is what sources gave.
      # A line matches when it holds every word, in any case, and the level as a word of its own.
      # before is the time a line starts with: only lines from before it are given.
      def call(days, words: [], level: nil, before: nil)
        Copies.tidy
        days = days.reject { |(_, day), _| day > before[0, 10] } if before
        problems = []
        lines = newest(days, filters(words.uniq.first(WORDS), level, before), problems)
        [lines.sort_by(&:last).last(LIMIT), problems]
      end

      private

      # From the last day back, and no further than it takes: the days before only have older lines.
      def newest(days, filters, problems)
        days.group_by { |(_, day), _| day }.sort.reverse_each.with_object([]) do |(_, streams), found|
          streams.each do |(stream, day), keys|
            found.concat(matches(stream, Copies.path(stream, day, keys), filters))
          rescue Error => e
            @listed = nil # it may be the listing that is no longer true
            problems << "#{stream} #{day}: #{e.message}"
          end
          break found if found.size >= LIMIT
        end
      end

      def stream_and_day(key)
        key.match(DAY_FILE)&.captures&.first(2) || key.split("/")[1, 2]
      end

      # Listing every part is the slow part of a search that has its copies, so a listing is used again
      # for a while. A key that is gone by the time it is fetched is noticed there.
      def listed(prefix)
        at, keys = (@listed ||= {})[[Logsafe.storage, prefix]]
        return keys if at && Time.now - at < LIST_FOR

        @listed.delete_if { |_, (time, _)| Time.now - time >= LIST_FOR }
        (@listed[[Logsafe.storage, prefix]] = [Time.now, Logsafe.storage.keys(prefix)]).last
      end

      # The system's tools, so that the size of a day does not matter. Nothing goes through a shell.
      # The lines are in time order, so awk can stop at the first one that is too late.
      def filters(words, level, before)
        [
          (["awk", "-v", "b=#{before}", '($0 "") >= (b "") { exit } 1'] if before),
          (["grep", "-a", "-i", "-w", "-E", LEVELS.fetch(level)] if level),
          *words.map { |word| ["grep", "-a", "-i", "-F", "-e", word] },
          ["tail", "-n", LIMIT.to_s]
        ].compact.map { |filter| [Copies::C, *filter] }
      end

      def matches(stream, log, filters)
        Open3.pipeline_r(*filters, in: log) { |out, _| out.readlines(chomp: true).map { |line| [stream, line] } }
      end
    end
  end
end

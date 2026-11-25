# frozen_string_literal: true

require "open3"
require "tmpdir"

module Logsafe
  # Finds lines in the days asked for, in the copies of those days on this machine: see Copies.
  module Search
    LIMIT = 500
    WORDS = 8 # each word is one more pass over the lines
    SAME = 2000 # lines of one time that can be paged through
    STREAMS = 50 # at once: each has its files fetched, and processes of its own
    LIST_FOR = 60 # seconds a listing of the storage is believed: parts come once a minute
    LISTING = Mutex.new
    LEVELS = { "debug" => "debug", "info" => "info", "warn" => "warn|warning",
               "error" => "error", "fatal" => "fatal" }.freeze
    DAY_FILE = %r{\A\d{4}/\d{2}/(#{STREAM})\.(\d{4}-\d{2}-\d{2})\.log\.gz(\.enc)?\z}

    class << self
      # { [stream, day] => keys } for what the storage has of the days from..to (dates): each day's
      # file, and the parts that are not in it yet.
      def sources(from, to)
        days = (from..to).map(&:to_s)
        found = files(from, to).merge(Logsafe.parts(listed(PARTS))) { |_, file, parts| file + parts }
        found.select { |(_, day), _| days.include?(day) }
      end

      # The last LIMIT lines that match, oldest first, as [stream, line], and then what could not be
      # read, as texts: one stream that fails does not hide the others. days is what sources gave.
      # A line matches when it holds every word, in any case, and the level as a word of its own.
      # before is the time a line starts with: only lines from before it are given. With skip, the lines
      # of that time too, but for this many that came last: those were on the page after.
      def call(days, words: [], level: nil, before: nil, skip: nil)
        Copies.tidy
        days = days.reject { |(_, day), _| day > before[0, 10] } if before
        problems = []
        lines = Dir.mktmpdir("logsafe-search") do |dir|
          newest(days, filters(written(words, dir), level, [before, skip]), LIMIT + skip.to_i, problems)
        end
        [lines.first([lines.size - skip.to_i, 0].max).last(LIMIT), problems]
      end

      private

      # The days' files, as sources gives them.
      def files(from, to)
        months = (from..to).map { |date| date.strftime("%Y/%m/") }.uniq
        keys = months.flat_map { |month| listed(month) }.grep(DAY_FILE)
        files = keys.group_by { |key| key.match(DAY_FILE).captures.first(2) }
        files.select { |(stream, _), _| Logsafe.stream?(stream) }
      end

      # From the last day back, and no further than it takes: the days before only have older lines.
      # In order, and no more of them at any time than are needed.
      def newest(days, filters, limit, problems)
        days.group_by { |(_, day), _| day }.sort.reverse_each.with_object([]) do |(_, streams), found|
          streams.each do |(stream, day), keys|
            found.concat(of_a_day(stream, day, keys, filters, problems))
            found.replace(found.sort_by(&:reverse).last(limit))
          end
          break found if found.size >= limit
        end
      end

      # What fails here, such as a file that the storage will not give, must not hide the other streams.
      def of_a_day(stream, day, keys, filters, problems)
        log, left_out = Copies.path(stream, day, keys)
        problems << "#{stream} #{day}: #{left_out.size} of its parts cannot be read. #{left_out.first}" if left_out.any?
        matches(stream, log, filters)
      rescue StandardError => e
        LISTING.synchronize { @listed = nil } # it may be the listing that is no longer true
        problems << "#{stream} #{day}: #{Day.reason(e)}"
        []
      end

      # Listing every part is the slow part of a search that has its copies, so a listing is used again
      # for a while. A key that is gone by the time it is fetched is noticed there.
      # One thread at a time: a server's threads share the listings, and a second search that comes
      # while the storage is being listed waits for that listing and does not ask for its own.
      def listed(prefix)
        LISTING.synchronize do
          at, keys = (@listed ||= {})[[Logsafe.storage, prefix]]
          next keys if at && Time.now - at < LIST_FOR

          @listed.delete_if { |_, (time, _)| Time.now - time >= LIST_FOR }
          (@listed[[Logsafe.storage, prefix]] = [Time.now, Logsafe.storage.keys(prefix)]).last
        end
      end

      # The system's tools, so that the size of a day does not matter. Nothing goes through a shell.
      # The lines are in time order, so awk can stop at the first one that is too late.
      def filters(words, level, (before, skip))
        late = "substr($0, 1, 30) #{skip ? ">" : ">="} (b \"\") { exit } 1"
        [
          (["awk", "-v", "b=#{before}", late] if before),
          (["grep", "-a", "-i", "-w", "-E", LEVELS.fetch(level)] if level),
          *words.map { |word| ["grep", "-a", "-i", "-F", "-f", word] },
          ["tail", "-n", (LIMIT + skip.to_i).to_s]
        ].compact.map { |filter| [Copies::C, *filter] }
      end

      # Each word in a file that only this user can read: the arguments of a command are for everyone
      # on the machine to see, and what is searched for can be an address or a token.
      def written(words, dir)
        words.uniq.first(WORDS).each_with_index.map do |word, index|
          File.join(dir, index.to_s).tap { |path| File.write(path, "#{word}\n") }
        end
      end

      # grep ends with 1 when it finds nothing. Anything else, and some of the lines may be missing.
      def matches(stream, log, filters)
        lines, ends = Open3.pipeline_r(*filters, in: log) do |out, waits|
          [out.binmode.readlines(chomp: true), waits.map { |wait| wait.value.exitstatus }]
        end
        raise Error, "the search failed" unless (ends - [0, 1]).empty?

        lines.map { |line| [stream, line.force_encoding("UTF-8").scrub] }
      end
    end
  end
end

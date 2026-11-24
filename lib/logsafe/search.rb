# frozen_string_literal: true

require "digest"
require "open3"

module Logsafe
  # Finds lines in the days asked for. To search a day this machine needs its lines in plain text, so
  # the day's file and its parts are fetched and decrypted once, into a folder only this user can
  # read, and the copy is kept while it is in use. A copy nobody used for KEEP seconds is deleted.
  # KEEP is shorter than the hour between two merges on purpose: a part that arrives late is listed
  # for at least that hour, so a copy either sees it or is gone before the part is.
  # ponytail: one lock for all days, so a large first download holds up the other searches, and no
  # limit to the size of the folder; a lock per day and a limit if either is ever felt.
  module Search
    LIMIT = 500
    KEEP = 30 * 60
    LEVELS = { "debug" => "debug", "info" => "info", "warn" => "warn|warning",
               "error" => "error", "fatal" => "fatal" }.freeze
    DAY_FILE = %r{\A\d{4}/\d{2}/([^/]+)\.(\d{4}-\d{2}-\d{2})\.log\.gz(\.enc)?\z}
    C = { "LC_ALL" => "C" }.freeze # bytes, not letters: the order sort gave the lines, and no slow matching

    class << self
      # { [stream, day] => keys } for what the storage has of the days from..to (dates): each day's
      # file, and the parts that are not in it yet.
      def sources(from, to)
        storage = Logsafe.storage
        months = (from..to).map { |date| date.strftime("%Y/%m/") }.uniq
        keys = months.flat_map { |month| storage.keys(month) }.grep(DAY_FILE) + storage.keys(PARTS)
        days = (from..to).map(&:to_s)
        keys.group_by { |key| stream_and_day(key) }.select { |(_, day), _| days.include?(day) }
      end

      # The last LIMIT lines that match, oldest first, as [stream, line]. days is what sources gave.
      # A line matches when it holds every word, in any case, and the level as a word of its own.
      # before is the time a line starts with: only lines from before it are given.
      def call(days, words: [], level: nil, before: nil)
        tidy
        days = days.reject { |(_, day), _| day > before[0, 10] } if before
        newest(days, filters(words, level, before)).sort_by(&:last).last(LIMIT)
      end

      # Deletes the copies that were not used for KEEP seconds.
      def sweep
        locked do
          (Dir.children(dir) - ["lock"]).each do |name|
            File.delete(File.join(dir, name)) if File.mtime(File.join(dir, name)) < Time.now - KEEP
          end
        end
      end

      # Where the copies are. Made for this user alone, and not taken over from anyone else.
      def dir
        File.join(Dir.tmpdir, "logsafe-web").tap do |dir|
          FileUtils.mkdir_p(dir, mode: 0o700)
          mine = File.lstat(dir)
          raise Error, "#{dir} is not a folder of this user's own" unless mine.directory? && mine.owned?
        end
      end

      private

      # From the last day back, and no further than it takes: the days before only have older lines.
      def newest(days, filters)
        days.group_by { |(_, day), _| day }.sort.reverse_each.with_object([]) do |(_, streams), found|
          streams.each { |(stream, day), keys| found.concat(matches(stream, copy(stream, day, keys), filters)) }
          break found if found.size >= LIMIT
        end
      end

      def stream_and_day(key)
        key.match(DAY_FILE)&.captures&.first(2) || key.split("/")[1, 2]
      end

      # Now, and from then on without a search having to come: the last copies must not stay for good.
      def tidy
        sweep
        @sweeper = Thread.new { loop { sleep(KEEP) && sweep } } unless @sweeper&.alive?
      end

      def locked
        File.open(File.join(dir, "lock"), File::CREAT | File::RDWR) { |lock| lock.flock(File::LOCK_EX) && yield }
      end

      # The path of the day's lines, after adding what the storage has and the copy does not.
      def copy(stream, day, keys)
        log = File.join(dir, "#{Digest::SHA256.hexdigest("#{stream}/#{day}")}.log")
        list = log.sub(/log\z/, "keys")
        locked do
          had = File.exist?(log) && File.exist?(list) ? File.readlines(list, chomp: true) : []
          add(stream, day, keys - had, log) unless (keys - had).empty?
          File.write(list, (had | keys).join("\n"))
          FileUtils.touch(log) # in use
        end
        log
      end

      def add(stream, day, keys, log)
        Dir.mktmpdir("logsafe") do |tmp|
          lines = Logsafe.lines(stream, day, keys, tmp)
          system(C, "sort", "-m", "-u", "-o", "#{log}.new", lines, *[log].select { |path| File.exist?(path) }) ||
            raise(Error, "sort failed")
          File.rename("#{log}.new", log) # at once, for a search that is reading the copy
        end
      end

      # The system's tools, so that the size of a day does not matter. Nothing goes through a shell.
      def filters(words, level, before)
        [
          (["awk", "-v", "b=#{before}", '($0 "") < (b "")'] if before),
          (["grep", "-a", "-i", "-w", "-E", LEVELS.fetch(level)] if level),
          *words.map { |word| ["grep", "-a", "-i", "-F", "-e", word] },
          ["tail", "-n", LIMIT.to_s]
        ].compact.map { |filter| [C, *filter] }
      end

      def matches(stream, log, filters)
        Open3.pipeline_r(*filters, in: log) { |out, _| out.readlines(chomp: true).map { |line| [stream, line] } }
      end
    end
  end
end

# frozen_string_literal: true

require "digest"

module Logsafe
  # To search a day this machine needs its lines in plain text. So the day's file and its parts are
  # fetched and decrypted once, into a folder only this user can read, and the copy is kept while it
  # is in use: a later search fetches only what the storage has and the copy does not. A copy nobody
  # used for KEEP seconds is deleted, by the next search and by a thread of this process.
  # A copy knows what it holds by the names of the keys. So KEEP is shorter than the hour between two
  # merges: a part that arrives late is listed for at least that hour, and a copy either sees it or
  # is gone before the part is. Merges less than KEEP apart can make a copy miss such a part.
  # ponytail: a new part means writing the day's copy again, about once a minute for today; the
  # lock files stay, empty, one per day searched; and nothing limits the size of the folder but the
  # number of days a search may span. Parts of an hour each, and a limit, if any of it is ever felt.
  module Copies
    KEEP = 30 * 60
    SLICE = 1000 # keys fetched before what there is, is kept: a fetch that is cut off goes on from there
    WAIT = 5 # seconds for another search that is fetching the same day
    BUSY = "another search is fetching these logs right now. Load the page again in a moment."
    GONE = "the storage changed while it was read. Load the page again."
    C = { "LC_ALL" => "C" }.freeze # bytes, not letters: the order the merge's sort gave the lines

    class << self
      # The path of the day's lines, sorted, after adding what the storage has and the copy does not.
      def path(stream, day, keys)
        name = Digest::SHA256.hexdigest("#{Logsafe.storage}/#{stream}/#{day}")
        log = File.join(dir, "#{name}.log")
        locked(name, WAIT) { refresh(stream, day, keys, log) } || raise(Error, BUSY)
        log
      end

      # Deletes what was not used for KEEP seconds, and what a search that was cut off left behind.
      # What a search is working on is left alone.
      def sweep
        Dir.children(dir).grep_v(/\.lock\z/).each do |name|
          path = File.join(dir, name)
          locked(name[/\A\h+/], 0) { FileUtils.rm_rf(path) if File.mtime(path) < Time.now - KEEP }
        rescue Errno::ENOENT
          next # another process was first
        end
      end

      # Sweeps now, and from then on without a search having to come: the last copies must not stay.
      def tidy
        sweep
        @sweeper = Thread.new { loop { sleep(KEEP / 6) && sweep } } unless @sweeper&.alive?
      end

      # Where the copies are. For this user alone, and not taken over from anyone else.
      def dir
        File.join(Dir.tmpdir, "logsafe-web").tap do |dir|
          FileUtils.mkdir_p(dir, mode: 0o700)
          mine = File.lstat(dir)
          private = mine.directory? && mine.owned? && (mine.mode & 0o077).zero?
          raise Error, "#{dir} is not a folder that only this user can read" unless private
        end
      end

      private

      # Runs the block when nobody else is at this copy, waiting up to wait seconds for that.
      # Returns what the block gave, or nothing when the copy stayed taken.
      def locked(name, wait)
        File.open(File.join(dir, "#{name}.lock"), File::CREAT | File::RDWR) do |lock|
          give_up = Time.now + wait
          until (mine = lock.flock(File::LOCK_EX | File::LOCK_NB))
            break if Time.now >= give_up

            sleep(0.1)
          end
          yield if mine
        end
      end

      def refresh(stream, day, keys, log)
        list = log.sub(/log\z/, "keys")
        had = File.exist?(log) && File.exist?(list) ? File.readlines(list, chomp: true) : []
        (keys - had).each_slice(SLICE) do |slice|
          add(stream, day, slice, log)
          File.write(list, (had |= slice).join("\n"))
        end
        FileUtils.touch([log, list]) # in use
      end

      # A day's file is sorted as it is, and the parts are sorted here: what is left is to merge them.
      # In a folder beside the copy, so that a new copy is moved into place and not written twice.
      def add(stream, day, keys, log)
        Dir.mktmpdir("#{File.basename(log, ".log")}.", dir) do |work|
          merge(runs(stream, day, keys, work) + [log].select { |path| File.exist?(path) }, log)
        end
      rescue StandardError => e
        raise if e.is_a?(Error) || !gone?(keys)

        raise Error, GONE
      end

      def runs(stream, day, keys, work)
        files, parts = keys.partition { |key| key.match?(Search::DAY_FILE) }
        runs = files.map { |file| Logsafe.lines(stream, day, [file], Dir.mktmpdir("file", work), sorted: true) }
        parts.any? ? runs << Logsafe.lines(stream, day, parts, work) : runs
      end

      # Moved into place at once, for a search that is reading the copy.
      def merge(runs, log)
        return File.rename(runs.first, log) if runs.size == 1

        system(C, "sort", "-m", "-u", "-o", "#{log}.new", *runs) || raise(Error, "sort failed")
        File.rename("#{log}.new", log)
      end

      # Whether the storage no longer has one of these keys: the merge job removes the parts it has merged.
      def gone?(keys)
        folders = keys.map { |key| "#{File.dirname(key)}/" }.uniq
        (keys - folders.flat_map { |folder| Logsafe.storage.keys(folder) }).any?
      end
    end
  end
end

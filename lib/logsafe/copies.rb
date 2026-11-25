# frozen_string_literal: true

require "digest"

module Logsafe
  # To search a day this machine needs its lines in plain text. So the day's file and its parts are
  # fetched and decrypted once, into a folder only this user can read, and the copy is kept while it
  # is in use: a later search fetches only what the storage has and the copy does not. A copy nobody
  # used for KEEP seconds is deleted, by the next search and by a thread of this process, and every
  # copy when this process ends.
  # A copy knows what it holds by the names of the keys. So KEEP is shorter than the hour between two
  # merges: a part that arrives late is listed for at least that hour, and a copy either sees it or
  # is gone before the part is. Merges less than KEEP apart can make a copy miss such a part.
  # A part that cannot be read is left out, and remembered, so that it is not fetched for every search.
  # The copies take no more of the disk than they leave free: the ones not used for longest go first.
  # ponytail: a new part means writing the day's copy again, about once a minute for today; and the
  # lock files stay, empty, one per day searched. Parts of an hour each, if that is ever felt.
  module Copies
    KEEP = 30 * 60
    SLICE = 1000 # keys fetched before what there is, is kept: a fetch that is cut off goes on from there
    WAIT = 5 # seconds for another search that is fetching the same day
    WIDTH = 16 << 10 # bytes of a line that are kept, as many as Docker has in one
    BUSY = "another search is fetching these logs right now. Load the page again in a moment."
    GONE = "the storage changed while it was read. Load the page again."
    C = { "LC_ALL" => "C" }.freeze # bytes, not letters: the order the merge's sort gave the lines

    class << self
      # The path of the day's lines, sorted, after adding what the storage has and the copy does not.
      # And what is not in it because it could not be read, as a text for each part.
      def path(stream, day, keys)
        name = Digest::SHA256.hexdigest("#{Logsafe.storage}/#{stream}/#{day}")
        log = File.join(dir, "#{name}.log")
        left_out = locked(name, WAIT) { refresh(Day.new(stream, day), keys, log) } || raise(Error, BUSY)
        [log, left_out]
      end

      # Deletes what was not used for this many seconds, and what a search that was cut off left behind.
      # What a search is working on is left alone.
      def sweep(unused_for = KEEP)
        Dir.children(dir).grep_v(/\.lock\z/).each do |name|
          path = File.join(dir, name)
          locked(name[/\A\h+/], 0) { FileUtils.rm_rf(path) if File.mtime(path) <= Time.now - unused_for }
        rescue Errno::ENOENT
          next # another process was first
        end
      end

      # Sweeps now, and from then on without a search having to come: the last copies must not stay.
      # Nor may they outlive the process: when it ends, every copy goes, and another process that
      # shares the folder fetches again. A fork has no thread, but it has its parent's at_exit.
      def tidy
        sweep
        return if @sweeper&.alive?

        at_exit { sweep(0) } unless @sweeper
        @sweeper = Thread.new { loop { sleep(KEEP / 6) && sweep } }
      end

      def dir
        PrivateFolder.path("logsafe-web")
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

      def refresh(day, keys, log)
        _, list, unread = beside(log)
        FileUtils.rm_f([list, unread]) unless File.exist?(log)
        FileUtils.touch([list, unread])
        had = File.readlines(list, chomp: true)
        passing = (keys - had).each_slice(SLICE).flat_map do |slice|
          again = take(day, slice, log, unread)
          File.write(list, (had |= slice - again.map(&:first)).join("\n"))
          again
        end
        FileUtils.touch([log, list, unread]) # in use
        File.readlines(unread) + texts(passing)
      end

      # The copy, the keys that are in it, and what of them could not be read.
      def beside(log)
        %w[log keys unread].map { |ending| log.sub(/log\z/, ending) }
      end

      # Adds these keys, and writes down the ones that cannot be read. Returns the ones to try again: what
      # the storage would not give now.
      def take(day, keys, log, unread)
        make_room
        lasting, passing = add(day, keys, log).partition { |_, error| error.is_a?(Error) }
        File.write(unread, texts(lasting).join, mode: "a")
        passing
      end

      def texts(bad)
        bad.map { |key, error| "#{key}: #{Day.reason(error)}\n" }
      end

      # A day's file is sorted as it is, and the parts are sorted here: what is left is to merge them.
      # In a folder beside the copy, so that a new copy is moved into place and not written twice.
      # Returns the parts that could not be read. One that the storage would not give may be gone.
      def add(day, keys, log)
        Dir.mktmpdir("#{File.basename(log, ".log")}.", dir) do |work|
          runs, bad = runs(day, keys, work)
          refused = bad.reject { |_, error| error.is_a?(Error) }
          raise Error, GONE if refused.any? && gone?(refused.keys)

          merge(runs + [log].select { |path| File.exist?(path) }, log)
          bad
        end
      rescue Error
        raise
      rescue StandardError
        raise unless gone?(keys)

        raise Error, GONE
      end

      def runs(day, keys, work)
        files, parts = keys.partition { |key| key.match?(Search::DAY_FILE) }
        runs = files.map { |file| day.lines([file], Dir.mktmpdir("file", work), sorted: true).first }
        sorted, bad = day.lines(parts, work) if parts.any?
        [[*runs, *sorted].map { |run| narrow(run) }, bad || {}]
      end

      # The page shows no more of a line than this, and need not hold more of it either.
      def narrow(run)
        system(C, "cut", "-b", "1-#{WIDTH}", in: run, out: "#{run}.cut") || raise(Error, "cut failed")
        File.delete(run)
        "#{run}.cut"
      end

      # Moved into place at once, for a search that is reading the copy.
      def merge(runs, log)
        return File.rename(runs.first, log) if runs.size == 1

        system(C, "sort", "-m", "-u", "-o", "#{log}.new", *runs) || raise(Error, "sort failed")
        File.rename("#{log}.new", log)
      end

      # Deletes the copies not used for longest, until they take no more than they leave free. A copy
      # that a search is adding to is left alone.
      def make_room
        logs = Dir.glob(File.join(dir, "*.log")).sort_by { |log| File.mtime(log) }
        over = logs.sum { |log| File.size(log) } - Room.free(dir)
        logs.each { |log| over -= 2 * evict(log) if over.positive? } # as much less taken, and as much more free
      rescue Errno::ENOENT
        nil # another process was first
      end

      # Returns the bytes it made free.
      def evict(log)
        size = File.size(log)
        locked(File.basename(log, ".log"), 0) { FileUtils.rm_f(beside(log)) } ? size : 0
      end

      # Whether the storage no longer has one of these keys: the merge job removes the parts it has merged.
      def gone?(keys)
        folders = keys.map { |key| "#{File.dirname(key)}/" }.uniq
        (keys - folders.flat_map { |folder| Logsafe.storage.keys(folder) }).any?
      end
    end
  end
end

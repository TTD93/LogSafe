# frozen_string_literal: true

require "digest"

module Logsafe
  # The logs of one stream of one day.
  class Day
    class << self
      # What could not be read, { part => error }, in a sentence.
      def left_out(bad)
        key, error = bad.first
        count = bad.size == 1 ? "1 part" : "#{bad.size} parts"
        "#{count} could not be read and stay where they are. The first: #{key}: #{reason(error)}"
      end

      def reason(error)
        text = error.message.lines.first.to_s.chomp
        error.is_a?(Error) ? text : "#{error.class}: #{text}"
      end
    end

    def initialize(stream, day)
      @stream = stream
      @day = day
      @key = Logsafe.keys.first
      @source = Source.new(stream, day, Logsafe.keys)
    end

    # The first run writes the day's file and leaves the parts. A later run finds that the parts add
    # nothing to the file, and only then removes them. So a part is never deleted on the word of the
    # run that uploaded it, and two runs at the same time cannot lose a line between them.
    # The day's file under its other name, from before the key was set, counts as a part:
    # so a day never ends up as two files, one of them in plain text.
    # A part that cannot be read stays where it is and does not hold up the others, but fails the run.
    # What version the file has is asked before it is read: a run that took long, or that began with
    # an older file, then cannot put it in place of one that another run has written meanwhile, whose
    # parts may be gone.
    def merge(parts)
      file, other = names
      version = Logsafe.storage.version(file)
      parts += [other] if Logsafe.storage.version(other)
      bad = Dir.mktmpdir("logsafe") { |dir| step(file, version, parts, dir) }
      raise Error, Day.left_out(bad) if bad.any?
    end

    # The lines of these keys, decrypted and sorted, in a file in dir. Returns its path, and what could
    # not be read as { part => error }. A day's file is in order as it is: say so, and it is not sorted again.
    def lines(keys, dir, sorted: false)
      bad = gather(keys, dir)
      [sorted ? File.join(dir, "all") : sort(dir), bad]
    end

    private

    # The name of the day's file, and the name it has with the key set the other way.
    def names
      plain = "#{@day[0, 4]}/#{@day[5, 2]}/#{@stream}.#{@day}.log.gz"
      @key ? ["#{plain}.enc", plain] : [plain, "#{plain}.enc"]
    end

    def step(file, version, parts, dir)
      bad = gather([*(file if version), *parts], dir, watch: file)
      good = parts - bad.keys
      return bad if good.empty?

      merged = sort(dir)
      if version && @text == digest(merged)
        Logsafe.storage.delete(good)
      else
        Logsafe.storage.store(pack(merged), file, version)
      end
      bad
    rescue Storage::Changed
      bad # another run was first, and the next one goes on from what it wrote
    end

    # All the lines of these keys as plain text in one file. Returns the parts that could not be read.
    # A day's file is not left out: the day would be written without it. Remembers what the text of the
    # day's file to watch was.
    # ponytail: with sort's own files this needs disk for three times a day's logs; feed sort
    # through a pipe if that is ever too much.
    def gather(keys, dir, watch: nil)
      room = Room.new(dir)
      bad = {}
      failed = ->(key, error) { set_aside(key, error, bad) }
      paths = Storage.fetch(Logsafe.storage, keys, dir, failed:) do |key, path|
        @source.plain(key, path, room.left)
        @text = digest(path) if key == watch
        room.take(File.size(path))
      end
      join(paths, File.join(dir, "all"))
      bad
    end

    def set_aside(key, error, bad)
      raise error if !key.start_with?(PARTS) || error.is_a?(Full) || error.is_a?(Errno::ENOSPC)

      bad[key] = error
    end

    def join(paths, into)
      File.open(into, "wb") do |all|
        paths.each do |path|
          IO.copy_stream(path, all)
          all << "\n" unless ends_with_line_break?(path) # or two lines would become one
          File.delete(path) # so the sources and their lines are not both on disk
        end
      end
    end

    def ends_with_line_break?(path)
      File.zero?(path) || File.open(path, "rb") { |file| file.seek(-1, IO::SEEK_END) && file.read(1) == "\n" }
    end

    # Every line starts with its time at a fixed width, so sorting the text sorts by time, and the
    # system's sort does it on disk however large the day is. -u keeps a line that is there twice
    # only once, which is what makes running again harmless.
    # ponytail: two identical lines in the same nanosecond become one; number the lines in
    # vector.yaml if that ever matters.
    def sort(dir)
      all = File.join(dir, "all")
      sorted = File.join(dir, "sorted")
      system({ "LC_ALL" => "C", "TMPDIR" => dir }, "sort", "-u", "-o", sorted, all) || raise(Error, "sort failed")
      File.delete(all)
      sorted
    end

    # The system's gzip and not Ruby's Zlib, here and in Source: Zlib fails with BufError when any
    # child process exits while it works (seen on Ruby 4.0), and a job worker starts processes often.
    def pack(path)
      system("gzip", "-n", path) || raise(Error, "gzip failed")
      @key ? Cipher.seal("#{path}.gz", "#{path}.gz.enc", @key, "#{@stream}/#{@day}") : "#{path}.gz"
    end

    def digest(path)
      Digest::SHA256.file(path).hexdigest
    end
  end
end

# frozen_string_literal: true

module Logsafe
  # Puts what was fetched for one stream and day into plain text, in its place and in the thread that
  # fetched it: a day of parts is a thousand runs of gzip.
  # A part is not trusted. Whoever may write parts, such as a server that was broken into, chooses
  # every byte of them. So what a part unpacks to and the length of a line have a limit, and every
  # line comes out with a time of its own day in front: order, paging and what is a line rest on that.
  class Source
    PART_LIMIT = 256 << 20 # bytes a compressed part may unpack to; Vector sends 10 MB at a time
    LINE_LIMIT = 2 << 20 # bytes of a line as it was sent; Vector reads lines of 1 MB at most
    TIME = /T\d{2}:\d{2}:\d{2}\.\d{9}Z /n

    class << self
      def gzip?(path)
        File.binread(path, 2) == GZIP
      end

      def gunzip(path, limit)
        system("gzip", "-dc", path, out: "#{path}.plain", err: File::NULL, rlimit_fsize: limit) ||
          raise(Error, "cannot be read: it is damaged, or unpacks to more than #{limit >> 20} MB")
        File.rename("#{path}.plain", path)
      ensure
        FileUtils.rm_f("#{path}.plain")
      end

      # Each line, with its line break.
      def each_line(path)
        File.foreach(path, "\n", LINE_LIMIT + 1, mode: "rb") do |line|
          raise Error, "a line is longer than #{LINE_LIMIT >> 20} MB" if line.bytesize > LINE_LIMIT

          yield line
        end
      end
    end

    def initialize(stream, day, keys)
      @name = "#{stream}/#{day}"
      @day = day
      @keys = keys
      @line_keys = Cipher.day_keys(keys, stream, day)
      @time = /\A#{day}#{TIME}/n
    end

    # limit is for a day's file, which can be of any size.
    def plain(key, path, limit)
      key.start_with?(PARTS) ? part(path) : day_file(key, path, limit)
    end

    # Encrypted or not is said by each line, compressed or not by the file: storages change names.
    def part(path)
      Source.gunzip(path, PART_LIMIT) if Source.gzip?(path)
      File.open("#{path}.plain", "wb") do |plain|
        Source.each_line(path) { |line| plain << text(line) }
      end
      File.rename("#{path}.plain", path)
    ensure
      FileUtils.rm_f("#{path}.plain")
    end

    private

    # One that is named as encrypted has to be, and for this stream and day. Otherwise whoever may
    # write to the storage could put a file of their own in its place.
    def day_file(key, path, limit)
      File.rename(Cipher.unseal(path, "#{path}.open", @keys, @name), path) if key.end_with?(".enc")
      Source.gunzip(path, limit) if Source.gzip?(path)
    end

    # A line whose time is not of this day keeps what it says, behind the start of the day.
    def text(line)
      text = Cipher.plain(line, @line_keys).delete_suffix("\n")
      raise Error, "an encrypted line holds a line break" if text.include?("\n")
      return "" if text.empty?

      text.match?(@time) ? "#{text}\n" : "#{@day}T00:00:00.000000000Z #{text}\n"
    end
  end
end

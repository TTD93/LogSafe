# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"
require_relative "logsafe/version"
require_relative "logsafe/storage"
require_relative "logsafe/cipher"

# Turns the parts a log shipper left in storage into one sorted file per stream per day:
#   parts/<stream>/<date>/*  ->  <year>/<month>/<stream>.<date>.log.gz
# With a key, encrypted: see Logsafe::Cipher.
module Logsafe
  class Error < StandardError; end

  autoload :MergeJob, "logsafe/merge_job"

  PARTS = "parts/"
  DATE = /\A\d{4}-\d{2}-\d{2}\z/
  GZIP = "\x1F\x8B".b

  class << self
    # Where the logs are: a folder, { s3: "bucket", ... } or { gcs: "bucket", ... }. See the README.
    def storage=(setting)
      @storage = Storage.build(setting)
    end

    def storage
      @storage || raise(Error, "Logsafe.storage is not set, see the README")
    end

    # The key from `logsafe key`. With it the day's file is encrypted, as <stream>.<date>.log.gz.enc,
    # and the lines a shipper encrypted with the same key can be read. Without it nothing is encrypted.
    def key=(text)
      @key = text && Cipher.key(text)
    end

    # The keys that were in use before, as a list or in one text with commas between them. What they
    # encrypted can still be read, and is encrypted with the key in use the next time it is written.
    def old_keys=(texts)
      @old_keys = Array(texts).flat_map { |text| text.scan(/[^\s,]+/) }.map { |text| Cipher.key(text) }
    end

    # Every key that can decrypt: the one in use first. Old keys alone open nothing, or a key that
    # went missing would have the merge write the days in plain text.
    def keys
      @key ? [@key, *@old_keys] : []
    end

    def generate_key
      Cipher.generate_key
    end

    # Turns a day's encrypted file back into its gzip.
    def decrypt(from, into)
      Cipher.unseal(from, into, keys)
    end

    # Merges every finished day (UTC) of the given streams, or of all streams. Safe to run again at
    # any time, and as often as you like. One day that fails does not hold up the others.
    def merge(*streams, today: Time.now.utc.strftime("%F"))
      failures = finished(streams, today).filter_map do |(stream, day), parts|
        merge_day(stream, day, parts)
        nil
      rescue StandardError => e
        warn "Logsafe could not merge #{stream} #{day}: #{e.class}: #{e.message.lines.first}"
        e
      end
      raise failures.first if failures.any?
    end

    private

    # { [stream, date] => [keys of its parts] } for the days that are over.
    def finished(streams, today)
      storage.keys(PARTS).group_by { |key| key.split("/")[1, 2] }.select do |(stream, day), _|
        day.to_s.match?(DATE) && day < today && (streams.empty? || streams.include?(stream))
      end
    end

    # The first run writes the day's file and leaves the parts. A later run finds that the parts add
    # nothing to the file, and only then removes them. So a part is never deleted on the word of the
    # run that uploaded it, and two runs at the same time cannot lose a line between them.
    # ponytail: a run that is still going when two later runs have finished can put back an older
    # file; add conditional writes (If-Match) to the storages if runs ever take that long.
    # The day's file under its other name, from before the key was set, counts as a part:
    # so a day never ends up as two files, one of them in plain text.
    def merge_day(stream, day, parts)
      file, other = names(stream, day)
      days = storage.keys("#{File.dirname(file)}/")
      earlier = days.include?(file)
      parts += [other] & days
      Dir.mktmpdir("logsafe") do |dir|
        sizes = gather([*(file if earlier), *parts], dir)
        merged = sort(dir, stream, day)
        next storage.delete(parts) if earlier && sizes.first == File.size(merged)

        storage.store(pack(merged), file)
      end
    end

    # The name of the day's file, and the name it has with the key set the other way.
    def names(stream, day)
      plain = "#{day[0, 4]}/#{day[5, 2]}/#{stream}.#{day}.log.gz"
      @key ? ["#{plain}.enc", plain] : [plain, "#{plain}.enc"]
    end

    # All the lines of the sources as plain text in one file. Returns what each source added.
    # ponytail: with sort's own files this needs disk for three times a day's logs; feed sort
    # through a pipe if that is ever too much.
    def gather(sources, dir)
      all = File.join(dir, "all")
      FileUtils.touch(all)
      sources.zip(Storage.fetch(storage, sources, dir)).map do |key, source|
        source = Cipher.unseal(source, "#{source}.gz", keys) if Cipher.sealed?(source)
        size = File.size(all)
        append(source, all) || raise(Error, "#{key} cannot be read, is it damaged?")
        File.write(all, "\n", mode: "a") unless ends_with_line_break?(all) # or two lines would become one
        FileUtils.rm_f([source, source.delete_suffix(".gz")]) # so the sources and their lines are not both on disk
        File.size(all) - size
      end
    end

    # Puts the lines a shipper encrypted back as they were, so that sorting, and keeping a line once,
    # are done on what the lines say. Costs nothing when there are none.
    def decrypt_lines(all, line_keys)
      system("grep", "-q", "^#{Cipher::LINE}", all)
      found = Process.last_status.exitstatus
      raise Error, "grep failed" unless [0, 1].include?(found) # or encrypted lines would go into the day's file
      return if found == 1

      File.open("#{all}.plain", "wb") do |plain|
        File.foreach(all, mode: "rb") { |line| plain << Cipher.plain(line, line_keys) }
      end
      File.rename("#{all}.plain", all)
    end

    # Encrypted or not, compressed or not, is read from the file itself: names and storages don't always agree.
    def append(source, all)
      return system("gzip", "-dc", source, out: [all, "a"], err: File::NULL) if File.binread(source, 2) == GZIP

      File.open(all, "ab") { |file| IO.copy_stream(source, file) }
    end

    def ends_with_line_break?(path)
      File.zero?(path) || File.open(path, "rb") { |file| file.seek(-1, IO::SEEK_END) && file.read(1) == "\n" }
    end

    # Every line starts with its time at a fixed width, so sorting the text sorts by time, and the
    # system's sort does it on disk however large the day is. -u keeps a line that is there twice
    # only once, which is what makes running again harmless.
    # ponytail: two identical lines in the same nanosecond become one; number the lines in
    # vector.yaml if that ever matters.
    def sort(dir, stream, day)
      all = File.join(dir, "all")
      sorted = File.join(dir, "sorted")
      decrypt_lines(all, Cipher.day_keys(keys, stream, day))
      system({ "LC_ALL" => "C", "TMPDIR" => dir }, "sort", "-u", "-o", sorted, all) || raise(Error, "sort failed")
      File.delete(all)
      sorted
    end

    # The system's gzip and not Ruby's Zlib, here and in append: Zlib fails with BufError when any
    # child process exits while it works (seen on Ruby 4.0), and a job worker starts processes often.
    def pack(path)
      system("gzip", "-n", path) || raise(Error, "gzip failed")
      @key ? Cipher.seal("#{path}.gz", "#{path}.gz.enc", @key) : "#{path}.gz"
    end
  end
end

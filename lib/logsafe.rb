# frozen_string_literal: true

require "fileutils"
require "pathname"
require "tmpdir"
require_relative "logsafe/version"
require_relative "logsafe/storage"

# Turns the parts a log shipper left in storage into one sorted file per stream per day:
#   parts/<stream>/<date>/*  ->  <year>/<month>/<stream>.<date>.log.gz
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
    def merge_day(stream, day, parts)
      file = "#{day[0, 4]}/#{day[5, 2]}/#{stream}.#{day}.log.gz"
      earlier = storage.keys("#{File.dirname(file)}/").include?(file)
      Dir.mktmpdir("logsafe") do |dir|
        sizes = gather([*(file if earlier), *parts], dir)
        merged = sort(dir)
        next storage.delete(parts) if earlier && sizes.first == File.size(merged)

        storage.store(pack(merged), file)
      end
    end

    # All the lines of the sources as plain text in one file. Returns what each source added.
    # ponytail: with sort's own files this needs disk for three times a day's logs; feed sort
    # through a pipe if that is ever too much.
    def gather(sources, dir)
      all = File.join(dir, "all")
      FileUtils.touch(all)
      sources.zip(Storage.fetch(storage, sources, dir)).map do |key, source|
        size = File.size(all)
        append(source, all) || raise(Error, "#{key} cannot be read, is it damaged?")
        File.write(all, "\n", mode: "a") unless ends_with_line_break?(all) # or two lines would become one
        FileUtils.rm_f(source) # so the sources and their lines are not both on disk
        File.size(all) - size
      end
    end

    # Compressed or not is read from the file itself: names and storages don't always agree.
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
    def sort(dir)
      all = File.join(dir, "all")
      sorted = File.join(dir, "sorted")
      system({ "LC_ALL" => "C", "TMPDIR" => dir }, "sort", "-u", "-o", sorted, all) || raise(Error, "sort failed")
      File.delete(all)
      sorted
    end

    # The system's gzip and not Ruby's Zlib, here and in append: Zlib fails with BufError when any
    # child process exits while it works (seen on Ruby 4.0), and a job worker starts processes often.
    def pack(path)
      system("gzip", "-n", path) || raise(Error, "gzip failed")
      "#{path}.gz"
    end
  end
end

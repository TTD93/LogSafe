# frozen_string_literal: true

require "date"
require "fileutils"
require "pathname"
require "tmpdir"
require_relative "logsafe/version"

# Turns the parts a log shipper left in storage into one sorted file per stream per day:
#   parts/<stream>/<date>/*  ->  <year>/<month>/<stream>.<date>.log.gz
# With a key, encrypted: see Logsafe::Cipher.
module Logsafe
  class Error < StandardError; end

  autoload :MergeJob, "logsafe/merge_job"
  autoload :Reencrypt, "logsafe/reencrypt"
  autoload :ReencryptJob, "logsafe/reencrypt_job"
  autoload :Copies, "logsafe/copies"
  autoload :Search, "logsafe/search"
  autoload :Web, "logsafe/web"

  PARTS = "parts/"
  DATE = /\A\d{4}-\d{2}-\d{2}\z/
  GZIP = "\x1F\x8B".b
  # What a stream can be called, as in shipper/vector.yaml: it becomes part of names of files. And what
  # is a part: nothing that could forge a line where its name is printed.
  STREAM = /[A-Za-z0-9][A-Za-z0-9._-]{0,199}/
  PART = %r{\A#{PARTS}(#{STREAM})/(\d{4}-\d{2}-\d{2})/[^[:cntrl:]]+\z}
  AGE = 366 # days. A part of a date before that is left alone: there are too many such dates to make up.
  RUN = 50 * 60 # seconds after which a merge starts with no other day, so that hourly runs do not pile up

  class << self
    # Where the logs are: a folder, { s3: "bucket", ... } or { gcs: "bucket", ... }. See the README.
    def storage=(setting)
      @storage = Storage.build(setting)
    end

    def storage
      @storage || raise(Error, "Logsafe.storage is not set, see the README")
    end

    # The names of the streams there are, if nothing else is to be merged, shown or encrypted again.
    # Whoever may write parts can make up any number of other names.
    def streams=(names)
      names &&= Array(names).map(&:to_s)
      wrong = names.to_a.grep_v(/\A#{STREAM}\z/)
      raise Error, "Logsafe.streams has a name that no stream can have: #{wrong.first.inspect}" if wrong.any?
      raise Error, "Logsafe.streams is empty. Leave it out to have every stream" if names == []

      @streams = names
    end

    def stream?(name)
      @streams.nil? || @streams.include?(name)
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

    # Encrypts with the key in use what the old keys encrypted and what was never encrypted: every
    # day's file and every part. When it has run without failing, the old keys can go.
    # A day's plain file goes the way of a part: the merge takes it into the encrypted file, and its
    # second run removes it, having found all of it there.
    def reencrypt
      Reencrypt.call(storage, @key || raise(Error, "Logsafe.key is not set"), @old_keys.to_a) do |stream, day|
        2.times { Day.new(stream, day).merge([]) }
      end
    end

    # Merges every finished day (UTC) of the given streams, or of all streams. Safe to run again at
    # any time, though no more than every half hour where the page is in use: see Copies. One day that
    # fails does not hold up the others. A run that
    # has gone on for RUN leaves the rest to the next one, and because the order is another each time,
    # those are not always the same.
    def merge(*streams, today: Time.now.utc.strftime("%F"))
      waiting = finished(streams, today).shuffle
      stop = clock + RUN
      failures = []
      failures.concat(attempt(*waiting.pop)) while waiting.any? && clock < stop
      warn "Logsafe leaves #{waiting.size} days to the next run: this one has taken long enough" if waiting.any?
      raise failures.first if failures.any?
    end

    # The parts among these keys, as { [stream, date] => keys }.
    def parts(keys)
      keys.group_by { |key| key.match(PART)&.captures }.select do |(stream, day), _|
        day && stream?(stream) && Date.valid_date?(*day.split("-").map(&:to_i))
      end
    end

    private

    # Merges a day, and returns what went wrong, if anything did.
    def attempt((stream, day), parts)
      Day.new(stream, day).merge(parts)
      []
    rescue StandardError => e
      warn "Logsafe could not merge #{stream} #{day}: #{e.class}: #{e.message.lines.first}"
      [e]
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # [[stream, date], [keys of its parts]] for the days that are over.
    def finished(streams, today)
      parts = recent((Date.iso8601(today) - AGE).to_s)
      parts.select { |(stream, day), _| day < today && (streams.empty? || streams.include?(stream)) }.to_a
    end

    def recent(oldest)
      keys = storage.keys(PARTS).reject { |key| key.end_with?("/") } # a folder, as some storages list them
      parts = parts(keys).select { |(_, day), _| day >= oldest }
      report(keys, keys.size - parts.values.sum(&:size))
      parts
    end

    # What is left alone is not lost, but it must be possible to notice.
    def report(keys, strays)
      return if strays.zero?

      others = keys.filter_map { |key| key[PART, 1] }.uniq.reject { |stream| stream?(stream) }
      warn "Logsafe leaves #{strays} files under #{PARTS} alone: not a stream's name, or not a date of the last year." \
           "#{" Not in Logsafe.streams: #{others.first(5).join(", ")}" if others.any?}"
    end
  end
end

require_relative "logsafe/room"
require_relative "logsafe/private_folder"
require_relative "logsafe/storage"
require_relative "logsafe/cipher"
require_relative "logsafe/source"
require_relative "logsafe/day"

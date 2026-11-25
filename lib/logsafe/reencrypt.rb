# frozen_string_literal: true

module Logsafe
  # Encrypts with the key in use everything in the storage that it does not open: what an old key
  # encrypted, and what was never encrypted. That is every day's file, and every line in the parts.
  # What the key in use already opens is left as it is, so it can be run again. When it has run
  # without failing, nothing that was in the storage is plain, or needs an old key.
  # ponytail: it reads every day's file and every part each time it runs; write which key sealed a
  # file in front of it if that ever takes too long.
  module Reencrypt
    DAY = %r{\A\d{4}/\d{2}/(#{STREAM})\.(\d{4}-\d{2}-\d{2})\.log\.gz\.enc\z}
    PLAIN_DAY = %r{\A\d{4}/\d{2}/(#{STREAM})\.(\d{4}-\d{2}-\d{2})\.log\.gz\z}
    ALL = Regexp.union(DAY, PLAIN_DAY, PART) # what the merge takes for a part, and nothing else under parts/

    class << self
      # One file that fails does not hold up the others. The block encrypts a day's plain file, given
      # its stream and day.
      def call(storage, key, old_keys, &encrypt_day)
        failures = storage.keys("").grep(ALL).select { |name| Logsafe.stream?(stream(name)) }.filter_map do |name|
          one(storage, name, [key, *old_keys], &encrypt_day)
          nil
        rescue StandardError => e
          warn "Logsafe could not encrypt #{name}: #{e.class}: #{e.message.lines.first}"
          e
        end
        raise failures.first if failures.any?
      end

      private

      def stream(name)
        name[PART, 1] || name[DAY, 1] || name[PLAIN_DAY, 1]
      end

      def one(storage, name, keys)
        return plain_day(storage, name) { yield(*PLAIN_DAY.match(name).captures) } if PLAIN_DAY.match?(name)

        Dir.mktmpdir("logsafe") do |dir|
          version = storage.version(name) # before it is read: a merge can write the file meanwhile
          storage.fetch(name, file = File.join(dir, "file"))
          again = name.start_with?(PARTS) ? part(name, file, keys) : day(name, file, *keys)
          storage.store(again, name, version) if again
        end
      end

      def plain_day(storage, name)
        yield
        left = storage.keys("#{File.dirname(name)}/").include?(name)
        raise Error, "#{name} is still there in plain text; is it in the folder of its own year and month?" if left
      end

      # The path of the file encrypted again, or nothing when the key in use opens it.
      def day(name, file, key, *old_keys)
        of = name.match(DAY).captures.join("/")
        Cipher.unseal(file, "#{file}.gz", [key], of)
        nil
      rescue Error
        raise if old_keys.empty?

        Cipher.seal(Cipher.unseal(file, "#{file}.gz", old_keys, of), "#{file}.enc", key, of)
      end

      # The same for a part, where each line is encrypted with the key of its stream and day.
      def part(name, file, keys)
        key, *old_keys = Cipher.day_keys(keys, *name.match(PART).captures)
        gzip = Source.gzip?(file)
        Source.gunzip(file, Source::PART_LIMIT) if gzip
        return unless rewrite(file, "#{file}.new") { |line| line(line, key, old_keys) }

        gzip ? pack("#{file}.new") : "#{file}.new"
      end

      # Whether any line became another.
      def rewrite(from, into)
        changed = false
        File.open(into, "wb") do |out|
          Source.each_line(from) do |line|
            again = yield(line)
            changed ||= again != line
            out << again
          end
        end
        changed
      end

      def line(line, key, old_keys)
        return seal(line.delete_suffix("\n"), key) unless line.start_with?(Cipher::LINE) # not chomp: a \r stays

        Cipher.plain(line, [key])
        line
      rescue Error
        raise if old_keys.empty?

        seal(Cipher.plain(line, old_keys).delete_suffix("\n"), key)
      end

      def seal(text, key)
        text.empty? ? "\n" : "#{Cipher.seal_line(text, key)}\n"
      end

      def pack(file)
        system("gzip", "-n", file) || raise(Error, "gzip failed")
        "#{file}.gz"
      end
    end
  end
end

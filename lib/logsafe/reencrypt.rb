# frozen_string_literal: true

module Logsafe
  # Encrypts with the key in use everything in the storage that it does not open: what an old key
  # encrypted, and what was never encrypted. That is every day's file, and every line in the parts.
  # What the key in use already opens is left as it is, so it can be run again. When it has run
  # without failing, nothing that was in the storage is plain, or needs an old key.
  # ponytail: it reads every day's file and every part each time it runs, and a part into memory;
  # write which key sealed a file in front of it if that ever takes too long.
  module Reencrypt
    DAY = %r{\A\d{4}/\d{2}/[^/]+\.log\.gz\.enc\z}
    PLAIN_DAY = %r{\A\d{4}/\d{2}/([^/]+)\.(\d{4}-\d{2}-\d{2})\.log\.gz\z}
    PART = %r{\A#{PARTS}[^/]+/\d{4}-\d{2}-\d{2}/.} # what the merge takes for a part, and nothing else under parts/
    ALL = Regexp.union(DAY, PLAIN_DAY, PART)

    class << self
      # One file that fails does not hold up the others. The block encrypts a day's plain file, given
      # its stream and day.
      def call(storage, key, old_keys, &encrypt_day)
        failures = storage.keys("").grep(ALL).filter_map do |name|
          one(storage, name, [key, *old_keys], &encrypt_day)
          nil
        rescue StandardError => e
          warn "Logsafe could not encrypt #{name}: #{e.class}: #{e.message.lines.first}"
          e
        end
        raise failures.first if failures.any?
      end

      private

      def one(storage, name, keys)
        return plain_day(storage, name) { yield(*PLAIN_DAY.match(name).captures) } if PLAIN_DAY.match?(name)

        Dir.mktmpdir("logsafe") do |dir|
          storage.fetch(name, file = File.join(dir, "file"))
          again = name.start_with?(PARTS) ? part(name, file, keys) : day(file, *keys)
          storage.store(again, name) if again
        end
      end

      def plain_day(storage, name)
        yield
        left = storage.keys("#{File.dirname(name)}/").include?(name)
        raise Error, "#{name} is still there in plain text; is it in the folder of its own year and month?" if left
      end

      # The path of the file encrypted again, or nothing when the key in use opens it.
      def day(file, key, *old_keys)
        Cipher.unseal(file, "#{file}.gz", [key])
        nil
      rescue Error
        raise if old_keys.empty?

        Cipher.seal(Cipher.unseal(file, "#{file}.gz", old_keys), "#{file}.enc", key)
      end

      # The same for a part, where each line is encrypted with the key of its stream and day.
      def part(name, file, keys)
        key, *old_keys = Cipher.day_keys(keys, *name.split("/")[1, 2])
        gzip = File.binread(file, 2) == GZIP
        lines = gzip ? unpack(name, file) : File.readlines(file, mode: "rb")
        again = lines.map { |line| line(line, key, old_keys) }
        return if again == lines

        File.binwrite(file, again.join)
        gzip ? pack(file) : file
      end

      def line(line, key, old_keys)
        return seal(line.delete_suffix("\n"), key) unless line.start_with?(Cipher::LINE) # not chomp: a \r stays

        Cipher.line(line.delete_prefix(Cipher::LINE), [key])
        line
      rescue Error
        raise if old_keys.empty?

        seal(Cipher.line(line.delete_prefix(Cipher::LINE), old_keys), key)
      end

      def seal(text, key)
        text.empty? ? "\n" : "#{Cipher.seal_line(text, key)}\n"
      end

      def unpack(name, file)
        lines = IO.popen(["gzip", "-dc", file], "rb", &:readlines)
        Process.last_status.success? ? lines : raise(Error, "#{name} cannot be read, is it damaged?")
      end

      def pack(file)
        system("gzip", "-n", file) || raise(Error, "gzip failed")
        "#{file}.gz"
      end
    end
  end
end

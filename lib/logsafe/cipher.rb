# frozen_string_literal: true

require "openssl"
require "securerandom"

module Logsafe
  # What the key seals, and how.
  # A day's file is its gzip under AES-256-GCM: "logsafe1", a 12-byte nonce, the sealed gzip, a 16-byte tag.
  # A line the shipper sealed (shipper/vector.yaml) is "enc:" and then, in Base64, a 12-byte nonce, the
  # line under ChaCha20-Poly1305 and a 16-byte tag. A line's key is not the key itself but
  # HMAC-SHA256(key, "<stream>/<day>"): so few lines share a key that the shipper's random nonces are
  # not expected to repeat under it.
  # To open something, each key is tried in turn: the one in use first, then the old ones.
  # ponytail: an old key costs one failed try per line or file it did not seal; write which key
  # sealed it in front if that ever shows. GCM seals at most 64 GB per file.
  module Cipher
    MAGIC = "logsafe1".b
    LINE = "enc:"
    NONCE = 12
    TAG = 16
    HEAD = MAGIC.bytesize + NONCE
    NO_KEY = "this is encrypted and Logsafe.key is not set"
    NOT_OURS = "was not encrypted with this key or an old one, or has been changed"

    class << self
      def generate_key
        SecureRandom.base64(32)
      end

      # The 32 bytes of a key as generate_key made it.
      def key(text)
        key = text.to_s.strip.unpack1("m0")
        key.bytesize == 32 ? key : raise(ArgumentError)
      rescue ArgumentError
        raise Error, "a Logsafe key must be 32 bytes in Base64; `logsafe key` prints a new one"
      end

      def day_keys(keys, stream, day)
        keys.map { |key| OpenSSL::HMAC.digest("SHA256", key, "#{stream}/#{day}") }
      end

      def sealed?(path)
        File.binread(path, MAGIC.bytesize) == MAGIC
      end

      # Returns the path of the sealed file.
      def seal(from, into, key)
        cipher = cipher("aes-256-gcm", :encrypt, key)
        File.open(into, "wb") do |out|
          out << MAGIC << cipher.random_iv
          File.open(from, "rb") { |file| pump(cipher, file, out, file.size) }
          out << cipher.final << cipher.auth_tag
        end
        into
      end

      # Returns the path of the opened file. Fails, and leaves nothing behind, unless the whole file is
      # what one of the keys sealed.
      def unseal(from, into, keys)
        fit(keys, "the file #{NOT_OURS}") { |key| open_file(from, into, key) }
      rescue Error
        FileUtils.rm_f(into)
        raise
      end

      # The text of one sealed line, given what follows LINE.
      def line(payload, keys)
        data = payload.unpack1("m")
        fit(keys, "a line #{NOT_OURS}") do |key|
          cipher = cipher("chacha20-poly1305", :decrypt, key, data[0, NONCE], data[-TAG..])
          cipher.update(data[NONCE...-TAG]) + cipher.final
        end
      end

      # A line sealed the way the shipper does it, without its line break.
      def seal_line(text, key)
        cipher = cipher("chacha20-poly1305", :encrypt, key)
        nonce = cipher.random_iv
        LINE + [nonce + cipher.update(text) + cipher.final + cipher.auth_tag].pack("m0")
      end

      # A line as it was before the shipper sealed it; a line that was never sealed, as it is.
      def plain(line, keys)
        line.start_with?(LINE) ? "#{line(line.delete_prefix(LINE), keys)}\n" : line
      end

      private

      # What the block gives with the first key that fits.
      def fit(keys, failure)
        raise Error, NO_KEY if keys.empty?

        keys.each do |key|
          return yield(key)
        rescue OpenSSL::Cipher::CipherError, ArgumentError, TypeError
          next
        end
        raise Error, failure
      end

      def open_file(from, into, key)
        File.open(from, "rb") do |file|
          body = file.size - HEAD - TAG
          raise ArgumentError unless file.read(MAGIC.bytesize) == MAGIC && body >= 0

          cipher = cipher("aes-256-gcm", :decrypt, key, file.read(NONCE), file.pread(TAG, HEAD + body))
          File.open(into, "wb") { |out| pump(cipher, file, out, body) << cipher.final }
        end
        into
      end

      # To open something, with its nonce and tag. A tag that is missing fails like one that is wrong.
      def cipher(name, mode, key, nonce = nil, tag = nil)
        cipher = OpenSSL::Cipher.new(name).public_send(mode)
        cipher.key = key
        return cipher if mode == :encrypt

        cipher.iv = nonce
        cipher.auth_tag = tag
        cipher
      end

      # A megabyte at a time, so the size of the file does not matter. Returns into.
      def pump(cipher, from, into, bytes)
        while bytes.positive?
          chunk = from.read([bytes, 1 << 20].min)
          into << cipher.update(chunk)
          bytes -= chunk.bytesize
        end
        into
      end
    end
  end
end

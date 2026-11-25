# frozen_string_literal: true

require "openssl"
require "securerandom"

module Logsafe
  # What the key seals, and how.
  # A day's file is its gzip under AES-256-GCM: "logsafe1", the length (2 bytes) and text of
  # "<stream>/<day>", a 12-byte nonce, what is sealed, a 16-byte tag. The name is sealed along with it,
  # so that one day's file cannot pass for another's. What is sealed is the gzip, zeros up to a multiple
  # of PAD, and the gzip's length in the last 8 bytes: the size of the file then says little about what
  # is in it. Someone who can add lines of their own could otherwise tell from how well they compress
  # whether they are like the others.
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
    PAD = 64 << 10
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

      # Returns the path of the sealed file. name is "<stream>/<day>".
      def seal(from, into, key, name)
        cipher = cipher("aes-256-gcm", :encrypt, key)
        File.open(into, "wb") do |out|
          out << (head = head_of(name)) << cipher.random_iv
          cipher.auth_data = head
          File.open(from, "rb") { |file| pump(cipher, file, out, file.size) << cipher.update(padding(file.size)) }
          out << cipher.final << cipher.auth_tag
        end
        into
      end

      # Returns the path of the opened file. Fails, and leaves nothing behind, unless the whole file is
      # what one of the keys sealed, and under this name if one is given.
      def unseal(from, into, keys, name = nil)
        fit(keys, "the file #{NOT_OURS}") { |key| open_file(from, into, key, name) }
      rescue Error
        FileUtils.rm_f(into)
        raise
      end

      # The text of one sealed line, given what follows LINE. Strict about the Base64: what follows its
      # end would otherwise be dropped unseen.
      def line(payload, keys)
        fit(keys, "a line #{NOT_OURS}") do |key|
          data = payload.unpack1("m0")
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
        line.start_with?(LINE) ? "#{line(line.delete_prefix(LINE).delete_suffix("\n"), keys)}\n" : line
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

      def open_file(from, into, key, name)
        File.open(from, "rb") do |file|
          head = head(file, name)
          nonce = file.read(NONCE)
          body = file.size - file.pos - TAG
          raise ArgumentError if body < 8

          cipher = cipher("aes-256-gcm", :decrypt, key, nonce, file.pread(TAG, file.size - TAG))
          cipher.auth_data = head
          File.open(into, "wb") { |out| pump(cipher, file, out, body) << cipher.final }
        end
        trim(into)
      end

      # What comes before the nonce.
      def head_of(name)
        MAGIC + [name.bytesize].pack("n") + name.b
      end

      def head(file, name)
        magic = file.read(MAGIC.bytesize)
        length = file.read(2).to_s.unpack1("n")
        raise ArgumentError unless magic == MAGIC && length

        found = file.read(length).to_s
        raise ArgumentError unless found.bytesize == length
        raise Error, "this is the file of #{found.inspect}, not of #{name}" if name && found != name.b

        head_of(found)
      end

      def padding(size)
        ("\0" * (-(size + 8) % PAD)) + [size].pack("Q>")
      end

      # Back to what was sealed, without its padding.
      def trim(path)
        File.open(path, "r+b") do |file|
          size = file.pread(8, file.size - 8).unpack1("Q>")
          size <= file.size - 8 ? file.truncate(size) : raise(ArgumentError)
        end
        path
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

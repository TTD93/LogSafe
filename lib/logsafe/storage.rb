# frozen_string_literal: true

require "securerandom"

module Logsafe
  # The places logs can live. Each one answers four messages, and so can an object of your own:
  #   keys(prefix)      the keys that start with prefix, which ends in "/"
  #   fetch(key, path)  copy the key's content to a local file; called from several threads at once
  #   store(path, key)  copy a local file to the key
  #   delete(keys)
  module Storage
    # Copies the keys to files in dir, several at a time: a day can be more than a thousand parts.
    # Returns the paths, in the order of the keys. Stops at the first key that fails, and raises what it raised.
    def self.fetch(storage, keys, dir)
      paths = keys.each_index.map { |index| File.join(dir, "source#{index}") }
      jobs = Queue.new(keys.zip(paths)).close
      failure = nil
      Array.new(8) do
        Thread.new do
          while (job = jobs.pop) do storage.fetch(*job) end
        rescue StandardError => e
          jobs.clear
          failure ||= e
        end
      end.each(&:join)
      failure ? raise(failure) : paths
    end

    def self.build(setting)
      case setting
      in String | Pathname then Folder.new(setting.to_s)
      in { folder: } then Folder.new(folder.to_s)
      in { s3: String => bucket, **options } then S3.new(S3.bucket(bucket, options))
      in { gcs: String => bucket, **options } then GCS.new(GCS.bucket(bucket, options))
      else setting
      end
    end

    # A folder: a local disk, a mounted volume or a network share.
    class Folder
      SETTLE = 120 # seconds; a shipper appends to its files, so a part is left alone while it is fresh

      def initialize(root)
        @root = root
      end

      def keys(prefix)
        Dir.glob("**/*", base: File.join(@root, prefix)).filter_map do |name|
          key = prefix + name
          key if File.file?(path(key)) && !fresh_part?(key)
        end
      end

      def fetch(key, path)
        FileUtils.cp(path(key), path)
      end

      # Written beside the folder's other files and then renamed, so nobody sees half a file. Under a
      # name of its own: two jobs in one process, or in two containers, would share one made from the pid.
      def store(path, key)
        FileUtils.mkdir_p(File.dirname(path(key)))
        FileUtils.cp(path, temporary = File.join(@root, ".logsafe-#{SecureRandom.hex(8)}"))
        File.rename(temporary, path(key))
      end

      def delete(keys)
        keys.each { |key| File.delete(path(key)) }
        keys.map { |key| File.dirname(path(key)) }.uniq.each { |dir| Dir.rmdir(dir) if Dir.empty?(dir) }
      end

      private

      def path(key)
        File.join(@root, key)
      end

      def fresh_part?(key)
        key.start_with?(PARTS) && File.mtime(path(key)) > Time.now - SETTLE
      end
    end

    # Amazon S3 and anything that speaks its protocol: DigitalOcean Spaces, MinIO, Garage, ...
    class S3
      def self.bucket(name, options)
        require "aws-sdk-s3"
        Aws::S3::Resource.new(**options).bucket(name)
      end

      def initialize(bucket)
        @bucket = bucket
      end

      def keys(prefix)
        @bucket.objects(prefix:).map(&:key)
      end

      def fetch(key, path)
        transfer.download_file(path, bucket: @bucket.name, key:)
      end

      def store(path, key)
        transfer.upload_file(path, bucket: @bucket.name, key:)
      end

      def delete(keys)
        keys.each_slice(1000) do |slice|
          failed = @bucket.delete_objects(delete: { objects: slice.map { |key| { key: } }, quiet: true }).errors
          raise Error, "could not delete #{failed.first.key}: #{failed.first.message}" if failed.any?
        end
      end

      private

      # Files of any size, in several pieces when they are large. Needs aws-sdk-s3 1.197 or newer.
      def transfer
        @transfer ||= Aws::S3::TransferManager.new(client: @bucket.client)
      end
    end

    # Google Cloud Storage.
    class GCS
      def self.bucket(name, options)
        require "google/cloud/storage"
        Google::Cloud::Storage.new(**options).bucket(name, skip_lookup: true)
      end

      def initialize(bucket)
        @bucket = bucket
      end

      def keys(prefix)
        @bucket.files(prefix:).all.map(&:name)
      end

      def fetch(key, path)
        @bucket.file(key, skip_lookup: true).download(path)
      end

      def store(path, key)
        @bucket.create_file(path, key)
      end

      def delete(keys)
        keys.each { |key| @bucket.file(key, skip_lookup: true).delete }
      end
    end
  end
end

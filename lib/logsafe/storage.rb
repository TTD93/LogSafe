# frozen_string_literal: true

require "securerandom"

module Logsafe
  # The places logs can live. Each one answers five messages, and so can an object of your own:
  #   keys(prefix)          the keys that start with prefix, which ends in "/", or is empty for all
  #   fetch(key, path)      copy the key's content to a local file; called from several threads at once
  #   version(key)          what tells the content the key has now from any other; nil when it has none
  #   store(path, key, was) copy a local file to the key, if the key still has the version it was, and
  #                         otherwise raise Changed: what was read before that is not the latest
  #   delete(keys)
  # and says in to_s which storage it is, when one machine reads from more than one. One that cannot
  # tell versions apart may give the same for every content: two runs at the same time are then not
  # kept from each other.
  module Storage
    # Someone else wrote first.
    class Changed < Error
      def initialize(key)
        super("#{key} was changed meanwhile")
      end
    end

    # Copies the keys to files in dir, several at a time: a day can be more than a thousand parts.
    # Gives each key and its file to the block, in the thread that fetched it, for work that can be
    # done side by side. Returns the paths, in the order of the keys. A key that fails, here or in the
    # block, is left out and given to failed with its error; when that raises, the rest is not fetched.
    def self.fetch(storage, keys, dir, failed: ->(_, error) { raise error })
      paths = keys.each_index.map { |index| File.join(dir, "source#{index}") }
      side_by_side(keys.zip(paths)) do |key, path|
        storage.fetch(key, path)
        yield(key, path)
      rescue StandardError => e
        FileUtils.rm_f(path)
        failed.call(key, e)
      end
      paths.select { |path| File.exist?(path) }
    end

    # Gives each item to the block, several at a time. Stops at the first that fails, and raises what it raised.
    def self.side_by_side(items)
      jobs = Queue.new(items).close
      failure = nil
      Array.new([8, items.size].min) do
        Thread.new do
          while (job = jobs.pop)
            yield(job)
          end
        rescue StandardError => e
          jobs.clear
          failure ||= e
        end
      end.each(&:join)
      raise failure if failure
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
    # What is below the root is opened one folder at a time, each from the handle of the one above, and
    # never through a symbolic link. Whoever may write to the folder, such as a server that was broken
    # into, could otherwise have this job read, replace or delete files anywhere on its machine.
    class Folder
      SETTLE = 120 # seconds; a shipper appends to its files, so a part is left alone while it is fresh
      OPEN = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      NEW = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW | File::BINARY
      HANDLES = "/proc/self/fd" # on Linux. Elsewhere by path, where a folder could be swapped in between.
      TEMPORARY = /\A\.logsafe-\h{16}\z/
      LOCK = ".logsafe-lock"
      WAIT = 30 # seconds for another store, which holds the lock for a moment

      def initialize(root)
        @root = root
      end

      # Which storage this is, for what is kept from it on this machine. The same below.
      def to_s
        "folder:#{File.expand_path(@root)}"
      end

      def keys(prefix)
        within(prefix) do |folder|
          Dir.glob("**/*", base: folder).filter_map do |name|
            key = prefix + name
            key if key.valid_encoding? && settled?(key, File.lstat(File.join(folder, name)))
          rescue Errno::ENOENT
            next # removed since it was listed
          end
        end
      rescue Errno::ENOENT
        []
      end

      def fetch(key, path)
        within(File.dirname(key)) do |folder|
          File.open(File.join(folder, File.basename(key)), OPEN) do |file|
            file.stat.file? ? IO.copy_stream(file, path) : raise(Error, "#{key} is not a file")
          end
        end
      end

      def version(key)
        within(File.dirname(key)) { |folder| stamp(File.join(folder, File.basename(key))) }
      rescue Errno::ENOENT
        nil
      end

      # Written beside its place and then renamed, so nobody sees half a file. Under a name of its own:
      # two jobs in one process, or in two containers, would share one made from the pid. Not for
      # everyone to read: Docker's own log files are not either.
      def store(path, key, was)
        FileUtils.mkdir_p(@root, mode: 0o750)
        within(File.dirname(key), create: true) do |folder|
          tidy(folder)
          temporary = File.join(folder, ".logsafe-#{SecureRandom.hex(8)}")
          File.open(temporary, NEW, 0o640) { |file| IO.copy_stream(path, file) }
          place = File.join(folder, File.basename(key))
          alone { stamp(place) == was ? File.rename(temporary, place) : raise(Changed, key) }
        ensure
          FileUtils.rm_f(temporary) if temporary
        end
      end

      # What is gone already, another run removed: two runs at the same time are no failure.
      def delete(keys)
        keys.each { |key| in_place(key) { |path| File.delete(path) } }
        keys.map { |key| File.dirname(key) }.uniq.each { |dir| in_place(dir) { |path| Dir.rmdir(path) } }
      end

      private

      # Opened, and not only looked at: a network share then asks its server.
      def stamp(path)
        File.open(path, OPEN) { |file| [file.stat.ino, file.stat.size, file.stat.mtime.to_r].join("-") }
      rescue Errno::ENOENT
        nil
      end

      # One store at a time, of all who share the folder.
      def alone
        File.open(File.join(@root, LOCK), File::RDWR | File::CREAT | File::NOFOLLOW, 0o640) do |lock|
          give_up = Time.now + WAIT
          until locked?(lock)
            raise Error, "#{LOCK} in the log folder is taken" if Time.now > give_up

            sleep(0.05)
          end
          yield
        end
      end

      # A share that has no locks leaves only the moment between the look and the rename.
      def locked?(lock)
        lock.flock(File::LOCK_EX | File::LOCK_NB)
      rescue Errno::ENOLCK, Errno::ENOTSUP, Errno::EOPNOTSUPP, Errno::ENOSYS
        true
      end

      def in_place(key)
        within(File.dirname(key)) { |folder| yield File.join(folder, File.basename(key)) }
      rescue Errno::ENOENT, Errno::ENOTEMPTY, Errno::EEXIST
        nil
      end

      # Gives the block a path to this folder that stays this folder, whatever is swapped meanwhile.
      def within(name, create: false)
        handles = [File.open(@root)]
        (name.split("/") - ["."]).each { |step| handles << enter(handles.last, step, create) }
        yield path_to(handles.last)
      rescue Errno::ELOOP, Errno::ENOTDIR
        raise Error, "#{name} in the log folder has a link in it, or is not a folder"
      ensure
        handles&.each(&:close)
      end

      def enter(handle, step, create)
        raise Errno::ENOTDIR if step == ".."

        path = File.join(path_to(handle), step)
        make(path) if create
        File.open(path, OPEN).tap do |folder|
          next if folder.stat.directory?

          folder.close
          raise Errno::ENOTDIR
        end
      end

      def make(path)
        Dir.mkdir(path, 0o750)
      rescue Errno::EEXIST
        nil
      end

      def path_to(handle)
        File.directory?(HANDLES) ? File.join(HANDLES, handle.fileno.to_s) : handle.path
      end

      # What a store that was killed left behind.
      def tidy(folder)
        Dir.children(folder).grep(TEMPORARY).each do |name|
          path = File.join(folder, name)
          File.delete(path) if File.lstat(path).mtime < Time.now - 86_400
        rescue Errno::ENOENT
          next
        end
      end

      def settled?(key, stat)
        stat.file? && !(key.start_with?(PARTS) && stat.mtime > Time.now - SETTLE)
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

      def to_s
        "s3:#{@bucket.client.config.endpoint}/#{@bucket.name}"
      end

      # In one request: left to itself the library asks for the size first, twice the requests for a
      # day's thousand parts. A file of several GB comes in one piece too, which is slower but works.
      def fetch(key, path)
        transfer.download_file(path, bucket: @bucket.name, key:, mode: "single_request")
      end

      def version(key)
        @bucket.object(key).etag
      rescue Aws::S3::Errors::NotFound
        nil
      end

      # The storage itself refuses to replace another version. Some that speak the protocol do not know
      # how, and say so or do as if they had: for those it is looked at just before.
      def store(path, key, was)
        raise Changed, key unless version(key) == was

        upload(path, key, was ? { if_match: was } : { if_none_match: "*" })
      rescue Aws::S3::Errors::ServiceError, Aws::S3::MultipartUploadError => e
        raise Changed, key unless version(key) == was
        raise unless codes(e).include?("NotImplemented")

        upload(path, key, {})
      end

      def delete(keys)
        keys.each_slice(1000) do |slice|
          failed = @bucket.delete_objects(delete: { objects: slice.map { |key| { key: } }, quiet: true }).errors
          raise Error, "could not delete #{failed.first.key}: #{failed.first.message}" if failed.any?
        end
      end

      private

      def upload(path, key, only_if)
        transfer.upload_file(path, bucket: @bucket.name, key:, **only_if)
      end

      def codes(error)
        errors = error.respond_to?(:errors) ? error.errors : [error]
        errors.filter_map { |one| one.code if one.respond_to?(:code) }
      end

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

      def to_s
        "gcs:#{@bucket.name}"
      end

      # As it is stored: left to itself the library unpacks gzip in memory, however much that comes to.
      def fetch(key, path)
        @bucket.file(key, skip_lookup: true).download(path, skip_decompress: true)
      end

      def version(key)
        @bucket.file(key)&.generation
      end

      # The storage itself refuses to replace another version; 0 is one that is not there.
      def store(path, key, was)
        @bucket.create_file(path, key, if_generation_match: was || 0)
      rescue Google::Cloud::FailedPreconditionError
        raise Changed, key
      end

      # One request per file, so several at a time. A file that is gone already, another run removed.
      def delete(keys)
        Storage.side_by_side(keys) do |key|
          @bucket.file(key, skip_lookup: true).delete
        rescue Google::Cloud::NotFoundError
          next
        end
      end
    end
  end
end

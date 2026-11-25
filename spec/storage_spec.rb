# frozen_string_literal: true

require "securerandom"

NEEDS_DOCKER = "needs the stand-ins that shipper/test starts"

RSpec.shared_context "with a storage" do
  def put(key, text, was: storage.version(key))
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "file"), text)
      storage.store(File.join(dir, "file"), key, was)
    end
  end

  def get(key)
    Dir.mktmpdir do |dir|
      storage.fetch(key, File.join(dir, "file"))
      File.binread(File.join(dir, "file"))
    end
  end
end

RSpec.shared_examples "a storage" do
  include_context "with a storage"

  before { Logsafe.storage = storage }

  it "stores, lists, fetches, replaces and deletes" do
    put "parts/web/2026-11-20/a.log", "one\n"
    put "parts/web/2026-11-20/b.log", "two\n"
    put "2026/11/web.2026-11-20.log.gz", "three\n"
    put "parts/web/2026-11-20/b.log", "two again\n"

    expect(storage.keys("parts/")).to contain_exactly("parts/web/2026-11-20/a.log", "parts/web/2026-11-20/b.log")
    expect(storage.keys("2026/11/")).to eq ["2026/11/web.2026-11-20.log.gz"]
    expect(get("parts/web/2026-11-20/b.log")).to eq "two again\n"

    2.times { storage.delete(["parts/web/2026-11-20/a.log", "parts/web/2026-11-20/b.log"]) } # as two runs would
    expect(storage.keys("parts/")).to eq []
    expect(storage.keys("2026/11/")).to eq ["2026/11/web.2026-11-20.log.gz"]
  end

  it "does not store over what it was not given the version of" do
    key = "2026/11/web.2026-11-20.log.gz"
    expect(storage.version(key)).to be_nil
    put key, "one\n"
    first = storage.version(key)
    expect(storage.version(key)).to eq first

    put key, "two\n"
    [first, nil].each { |was| expect { put key, "late\n", was: }.to raise_error(Logsafe::Storage::Changed) }
    expect { put "2026/11/none", "late\n", was: first }.to raise_error(Logsafe::Storage::Changed)
    expect(get(key)).to eq "two\n"
    expect(storage.version("2026/11/none")).to be_nil
  end

  # Each adds a line to what it read, and tries again when another was first: none may be lost.
  it "loses nothing when many store at the same time" do
    key = "2026/11/web.2026-11-20.log.gz"
    Array.new(8) do |number|
      Thread.new do
        version = storage.version(key)
        put key, "#{version ? get(key) : ""}#{number}\n", was: version
      rescue Logsafe::Storage::Changed
        retry
      end
    end.each(&:join)

    expect(get(key).lines.map(&:to_i).sort).to eq (0..7).to_a
  end

  it "holds a day that is merged into one file" do
    put "parts/web/2026-11-20/a.log.gz", Zlib.gzip("2026-11-20T10:00:00.000000002Z a2\n")
    put "parts/web/2026-11-20/b.log", "2026-11-20T10:00:00.000000001Z b1\n"

    2.times { Logsafe.merge(today: "2026-11-22") }

    expect(storage.keys("parts/")).to eq []
    expect(Zlib.gunzip(get("2026/11/web.2026-11-20.log.gz")).lines.map { |line| line.split.last }).to eq %w[b1 a2]
  end
end

RSpec.describe Logsafe::Storage do
  describe Logsafe::Storage::Folder do
    let(:root) { Dir.mktmpdir("logsafe-spec") }
    let(:storage) { Logsafe::Storage.build(root) }

    include_context "with a storage"

    before { stub_const("Logsafe::Storage::Folder::SETTLE", 0) }
    after { FileUtils.rm_rf(root) }

    it_behaves_like "a storage"

    # Whoever may write to the folder must not reach what is outside it, on the machine that merges.
    context "with links in it" do
      let(:outside) { Dir.mktmpdir("logsafe-outside") }

      before do
        Logsafe.storage = storage
        FileUtils.mkdir_p([File.join(root, "parts/web/2026-11-20"), File.join(outside, "web/2026-11-20")])
        File.write(File.join(outside, "web/2026-11-20/secret"), "2026-11-20T10:00:00.000000001Z secret\n")
      end

      after { FileUtils.rm_rf(outside) }

      it "does not read through a link to a file" do
        File.symlink(File.join(outside, "web/2026-11-20/secret"), File.join(root, "parts/web/2026-11-20/a.log"))

        expect(storage.keys("parts/")).to eq []
        expect { storage.fetch("parts/web/2026-11-20/a.log", File.join(outside, "copy")) }.to raise_error(Logsafe::Error)
        expect(File.exist?(File.join(outside, "copy"))).to be false
      end

      it "does not list, read, replace or delete through a link to a folder" do
        FileUtils.rm_rf(File.join(root, "parts"))
        File.symlink(outside, File.join(root, "parts"))
        key = "parts/web/2026-11-20/secret"

        expect { storage.keys("parts/") }.to raise_error(Logsafe::Error, /has a link in it/)
        expect { storage.fetch(key, File.join(outside, "copy")) }.to raise_error(Logsafe::Error)
        expect { put(key, "replaced\n") }.to raise_error(Logsafe::Error)
        expect { storage.delete([key]) }.to raise_error(Logsafe::Error)
        expect(File.read(File.join(outside, "web/2026-11-20/secret"))).to end_with "secret\n"
      end

      if File.directory?(Logsafe::Storage::Folder::HANDLES) # Linux
        it "stays in the folder it has opened, whatever is put in its place meanwhile" do
          inside = File.join(root, "parts/web/2026-11-20")
          File.write(File.join(inside, "secret"), "inside")

          storage.send(:within, "parts/web/2026-11-20") do |folder|
            File.rename(inside, "#{inside}-moved")
            File.symlink(File.join(outside, "web/2026-11-20"), inside)
            File.delete(File.join(folder, "secret"))
          end

          expect(File.exist?(File.join(outside, "web/2026-11-20/secret"))).to be true
          expect(Dir.children("#{inside}-moved")).to eq []
        end
      end

      it "does not go above itself" do
        expect { storage.fetch("parts/../../#{File.basename(outside)}/web/2026-11-20/secret", "/dev/null") }
          .to raise_error(Logsafe::Error)
      end
    end

    it "keeps its files from other users of the machine" do
      put "2026/11/web.2026-11-20.log.gz", "one\n"

      made = %w[2026 2026/11 2026/11/web.2026-11-20.log.gz]
      modes = made.map { |name| File.stat(File.join(root, name)).mode & 0o007 }
      expect(modes).to all(eq(0))
    end

    it "removes what a store that was killed left behind" do
      put "2026/11/web.2026-11-20.log.gz", "one\n"
      left = File.join(root, "2026/11/.logsafe-0123456789abcdef")
      File.write(left, "half")
      File.utime(Time.now - 90_000, Time.now - 90_000, left)

      put "2026/11/web.2026-11-21.log.gz", "two\n"
      expect(File.exist?(left)).to be false
    end

    it "leaves no empty folders or half-written files behind" do
      Logsafe.storage = storage
      FileUtils.mkdir_p(File.join(root, "parts/web/2026-11-20"))
      File.write(File.join(root, "parts/web/2026-11-20/a.log"), "2026-11-20T10:00:00.000000001Z a1\n")

      2.times { Logsafe.merge(today: "2026-11-22") }

      expect(Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |name| name.end_with?(".") })
        .to contain_exactly(".logsafe-lock", "2026", "2026/11", "2026/11/web.2026-11-20.log.gz", "parts", "parts/web")
    end
  end

  describe Logsafe::Storage::S3, skip: (NEEDS_DOCKER unless ENV["LOGSAFE_TEST_S3"]) do
    let(:options) do
      { endpoint: ENV.fetch("LOGSAFE_TEST_S3"), force_path_style: true, region: "us-east-1",
        access_key_id: "test", secret_access_key: "test" }
    end
    let(:storage) do
      name = "spec-#{SecureRandom.hex(4)}"
      Aws::S3::Resource.new(**options).create_bucket(bucket: name)
      Logsafe::Storage.build(s3: name, **options)
    end

    before { require "aws-sdk-s3" }

    it_behaves_like "a storage"
  end

  describe Logsafe::Storage::GCS, skip: (NEEDS_DOCKER unless ENV["LOGSAFE_TEST_GCS"]) do
    let(:storage) do
      require "google/cloud/storage"
      google = Google::Cloud::Storage.anonymous(endpoint: ENV.fetch("LOGSAFE_TEST_GCS"))
      Logsafe::Storage::GCS.new(google.create_bucket("spec-#{SecureRandom.hex(4)}"))
    end

    it_behaves_like "a storage"
  end

  it "takes a folder as a path or by name, and any object of your own" do
    own = Object.new

    expect(Logsafe::Storage.build("/tmp/logs")).to be_a Logsafe::Storage::Folder
    expect(Logsafe::Storage.build(Pathname("/tmp/logs"))).to be_a Logsafe::Storage::Folder
    expect(Logsafe::Storage.build(folder: "/tmp/logs")).to be_a Logsafe::Storage::Folder
    expect(Logsafe::Storage.build(own)).to be own
  end
end

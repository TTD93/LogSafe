# frozen_string_literal: true

require "securerandom"

NEEDS_DOCKER = "needs the stand-ins that shipper/test starts"

RSpec.shared_examples "a storage" do
  before { Logsafe.storage = storage }

  def put(key, text)
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "file"), text)
      storage.store(File.join(dir, "file"), key)
    end
  end

  def get(key)
    Dir.mktmpdir do |dir|
      storage.fetch(key, File.join(dir, "file"))
      File.binread(File.join(dir, "file"))
    end
  end

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

    before { stub_const("Logsafe::Storage::Folder::SETTLE", 0) }
    after { FileUtils.rm_rf(root) }

    it_behaves_like "a storage"

    it "leaves no empty folders or half-written files behind" do
      Logsafe.storage = storage
      FileUtils.mkdir_p(File.join(root, "parts/web/2026-11-20"))
      File.write(File.join(root, "parts/web/2026-11-20/a.log"), "2026-11-20T10:00:00.000000001Z a1\n")

      2.times { Logsafe.merge(today: "2026-11-22") }

      expect(Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |name| name.end_with?(".") })
        .to contain_exactly("2026", "2026/11", "2026/11/web.2026-11-20.log.gz", "parts", "parts/web")
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

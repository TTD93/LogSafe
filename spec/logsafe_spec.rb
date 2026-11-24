# frozen_string_literal: true

RSpec.describe Logsafe do
  let(:root) { Dir.mktmpdir("logsafe-spec") }

  before do
    described_class.storage = root
    allow(described_class).to receive(:warn)
  end

  after { FileUtils.rm_rf(root) }

  # A part as a shipper leaves it: parts/<stream>/<date>/<name>, written a while ago unless fresh.
  def part(key, *lines, gzip: false, fresh: false, text: lines.map { |line| "#{line}\n" }.join)
    path = File.join(root, "parts", key)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, gzip ? Zlib.gzip(text) : text)
    File.utime(Time.now - 600, Time.now - 600, path) unless fresh
  end

  def day_path(stream, day)
    File.join(root, day[0, 4], day[5, 2], "#{stream}.#{day}.log.gz")
  end

  def day_file(stream, day)
    Zlib.gunzip(File.binread(day_path(stream, day))).lines(chomp: true)
  end

  def files
    Dir.glob("**/*", base: root).select { |name| File.file?(File.join(root, name)) }.sort
  end

  def parts
    files.grep(%r{\Aparts/})
  end

  def merge(*streams)
    described_class.merge(*streams, today: "2026-11-22")
  end

  it "puts the lines of all servers into one file per day, in time order" do
    part "web/2026-11-20/server-a.log.gz", "2026-11-20T10:00:00.000000001Z a1", "2026-11-20T10:00:00.000000003Z a2",
         gzip: true
    part "web/2026-11-20/server-b.log", "2026-11-20T10:00:00.000000002Z b1", "2026-11-20T23:59:59.999999999Z b2"
    part "web/2026-11-21/server-a.log", "2026-11-21T00:00:00.000000000Z a3"

    merge

    expect(day_file("web", "2026-11-20")).to eq [
      "2026-11-20T10:00:00.000000001Z a1", "2026-11-20T10:00:00.000000002Z b1",
      "2026-11-20T10:00:00.000000003Z a2", "2026-11-20T23:59:59.999999999Z b2"
    ]
    expect(day_file("web", "2026-11-21")).to eq ["2026-11-21T00:00:00.000000000Z a3"]
  end

  it "removes the parts only once a later run has found them all in the day's file" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"

    merge
    expect(parts).to eq ["parts/web/2026-11-20/a.log"]

    merge
    expect(files).to eq ["2026/11/web.2026-11-20.log.gz"]
    expect(day_file("web", "2026-11-20")).to eq ["2026-11-20T10:00:00.000000001Z a1"]
  end

  it "keeps a line once when it was shipped twice" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1", "2026-11-20T10:00:00.000000002Z a2"
    part "web/2026-11-20/a-again.log", "2026-11-20T10:00:00.000000001Z a1"

    merge

    expect(day_file("web", "2026-11-20").map { |line| line[-2..] }).to eq %w[a1 a2]
  end

  it "adds a part that arrives late to a day that was already merged" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1", "2026-11-20T10:00:00.000000003Z a2"
    2.times { merge }
    part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"

    merge
    expect(day_file("web", "2026-11-20").map { |line| line.split.last }).to eq %w[a1 late a2]

    merge
    expect(files).to eq ["2026/11/web.2026-11-20.log.gz"]
  end

  it "gets a line back when another run put an older file in place" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    merge
    older = File.binread(day_path("web", "2026-11-20"))
    part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"
    merge

    File.binwrite(day_path("web", "2026-11-20"), older)
    merge

    expect(day_file("web", "2026-11-20").map { |line| line.split.last }).to eq %w[a1 late]
  end

  it "leaves today alone" do
    part "web/2026-11-22/a.log", "2026-11-22T08:00:00.000000000Z today"

    merge

    expect(files).to eq ["parts/web/2026-11-22/a.log"]
  end

  it "leaves a part alone while the shipper may still be writing it" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    part "web/2026-11-20/b.log", "2026-11-20T10:00:00.000000002Z b", fresh: true

    2.times { merge }

    expect(day_file("web", "2026-11-20").size).to eq 1
    expect(parts).to eq ["parts/web/2026-11-20/b.log"]
  end

  it "merges only the streams it is given" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    part "worker/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z w1"

    merge "worker"

    expect(files).to include("2026/11/worker.2026-11-20.log.gz").and include("parts/web/2026-11-20/a.log")
    expect(files).not_to include("2026/11/web.2026-11-20.log.gz")
  end

  it "does not join lines when a part ends without a line break" do
    part "web/2026-11-20/a.log", text: "2026-11-20T10:00:00.000000001Z a1"
    part "web/2026-11-20/b.log", "2026-11-20T10:00:00.000000002Z b1"

    merge

    expect(day_file("web", "2026-11-20").size).to eq 2
  end

  it "reads a compressed part to its end when it was written in several goes" do
    part "web/2026-11-20/a.log.gz",
         text: Zlib.gzip("2026-11-20T10:00:00.000000001Z a1\n") + Zlib.gzip("2026-11-20T10:00:00.000000002Z a2\n")

    merge

    expect(day_file("web", "2026-11-20").size).to eq 2
  end

  context "when a part cannot be read" do
    before do
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
      2.times { merge }
      part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"
      part "web/2026-11-20/broken.log.gz", text: "#{Logsafe::GZIP}this is not gzip"
      part "web/2026-11-21/a.log", "2026-11-21T00:00:00.000000000Z next day"
      part "worker/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z w1"
    end

    it "fails, and says which day" do
      expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz cannot be read/)
      expect(described_class).to have_received(:warn).with(/could not merge web 2026-11-20/)
    end

    it "keeps that day's file and all its parts" do
      expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz cannot be read/)

      expect(day_file("web", "2026-11-20")).to eq ["2026-11-20T10:00:00.000000001Z a1"]
      expect(parts).to include("parts/web/2026-11-20/late.log", "parts/web/2026-11-20/broken.log.gz")
    end

    it "still merges the other days and streams" do
      expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz cannot be read/)

      expect(day_file("web", "2026-11-21")).to eq ["2026-11-21T00:00:00.000000000Z next day"]
      expect(day_file("worker", "2026-11-20")).to eq ["2026-11-20T10:00:00.000000001Z w1"]
    end
  end

  it "says so when no storage was set" do
    described_class.instance_variable_set(:@storage, nil)

    expect { described_class.merge }.to raise_error(Logsafe::Error, /Logsafe.storage is not set/)
  end

  it "runs as a job on any Active Job backend" do
    Logsafe::MergeJob.logger = Logger.new(nil)
    Logsafe::MergeJob.queue_adapter = :inline
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    part "worker/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z w1"

    Logsafe::MergeJob.perform_later("web")
    Logsafe::MergeJob.perform_later

    expect(files).to include("2026/11/web.2026-11-20.log.gz", "2026/11/worker.2026-11-20.log.gz")
  end
end

# frozen_string_literal: true

require "uri"

RSpec.describe Logsafe::Web do
  let(:root) { Dir.mktmpdir("logsafe-spec") }
  let(:copies) { Dir.mktmpdir("logsafe-copies") }

  before do
    Logsafe.storage = root
    allow(Logsafe::Copies).to receive(:dir).and_return(copies)
    allow(Logsafe::Copies).to receive(:at_exit) # or the specs would end by sweeping this machine's real copies
    stub_const("Logsafe::Search::LIST_FOR", 0) # the specs change the storage and look again at once
  end

  after do
    Logsafe.key = nil
    FileUtils.rm_rf([root, copies])
  end

  # A part as a shipper left it a while ago: parts/<stream>/<date>/<name>.
  def part(key, *lines)
    path = File.join(root, "parts", key)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, lines.map { |line| "#{line}\n" }.join)
    File.utime(Time.now - 600, Time.now - 600, path)
  end

  def get(query = {})
    query = URI.encode_www_form(query) unless query.is_a?(String)
    status, headers, body = described_class.call("REQUEST_METHOD" => "GET", "QUERY_STRING" => query)
    expect(headers).not_to be_frozen # Rack::ETag and others write to them
    [status, body.join]
  end

  # The text of the lines on the page, top to bottom.
  def shown(query = {})
    get(query).last.scan(%r{</b> (.*?)</li>}).flatten.map { |text| text.gsub(/<.+?>/, "") }
  end

  def day(date, **query)
    { from: date, to: date, **query }
  end

  it "shows today's lines when nothing is asked for" do
    today = Time.now.utc.strftime("%F")
    part "web/#{today}/b.log", "#{today}T10:00:00.000000002Z second"
    part "web/#{today}/a.log", "#{today}T10:00:00.000000001Z first"
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z long ago"

    expect(shown).to eq %w[first second]
  end

  it "shows a day that is merged, with a part that came late, each line once" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1", "2026-11-20T10:00:00.000000003Z a3"
    Logsafe.merge(today: "2026-11-22")
    expect(shown(day("2026-11-20"))).to eq %w[a1 a3]

    Logsafe.merge(today: "2026-11-22")
    part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z a2"
    expect(shown(day("2026-11-20"))).to eq %w[a1 a2 a3]
  end

  context "with lines of two streams on three days" do
    before do
      part "web/2026-11-19/a.log", "2026-11-19T10:00:00.000000001Z INFO Started GET /orders"
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z ERROR Payment failed for order 7",
           "2026-11-20T10:00:00.000000003Z INFO no errors in order 8"
      part "worker/2026-11-20/a.log", "2026-11-20T10:00:00.000000002Z level=error job crashed"
      part "web/2026-11-21/a.log", "2026-11-21T10:00:00.000000001Z DEBUG order 9 cached"
    end

    let(:days) { { from: "2026-11-19", to: "2026-11-21" } }

    it "shows the days asked for, of all streams, in time order" do
      expect(shown(from: "2026-11-19", to: "2026-11-20")).to eq [
        "INFO Started GET /orders", "ERROR Payment failed for order 7", "level=error job crashed",
        "INFO no errors in order 8"
      ]
    end

    it "finds the lines that hold every word, in any case" do
      expect(shown(days.merge(q: "ORDER failed"))).to eq ["ERROR Payment failed for order 7"]
    end

    it "finds the lines of a level, however the program wrote it" do
      expect(shown(days.merge(level: "error"))).to eq ["ERROR Payment failed for order 7", "level=error job crashed"]
      expect(shown(days.merge(level: "debug"))).to eq ["DEBUG order 9 cached"]
    end

    it "shows one stream when asked" do
      expect(shown(days.merge(stream: "worker"))).to eq ["level=error job crashed"]
    end

    it "shows the last lines, and the ones before them on request" do
      stub_const("Logsafe::Search::LIMIT", 2)
      page = get(days).last
      expect(shown(days)).to eq ["INFO no errors in order 8", "DEBUG order 9 cached"]

      older = CGI.unescapeHTML(page[/href="\?(.+?)">Show older/, 1])
      expect(shown(older)).to eq ["ERROR Payment failed for order 7", "level=error job crashed"]
    end

    it "takes no harm from an address that was made up" do
      status, page = get(stream: "../../etc", from: "x", to: "2026-13-45", level: "x", before: "x; rm", q: "a\0b")
      expect(status).to eq 200
      expect(page).to include "The storage has no logs for these days."
      expect(get("q=\xC3\xA9").first).to eq 400 # not encoded
      expect(described_class.call("REQUEST_METHOD" => "POST").first).to eq 405
    end
  end

  it "shows what a line says and does not run it" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z <script>alert(1)</script> &amp;"

    page = get(day("2026-11-20", q: "script amp")).last

    expect(page).not_to include "<script>"
    expect(page).to include "&lt;<mark>script</mark>&gt;alert(1)&lt;/<mark>script</mark>&gt; &amp;<mark>amp</mark>;"
  end

  it "fetches only what it does not have yet" do
    allow(Logsafe.storage).to receive(:fetch).and_call_original
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    shown(day("2026-11-20"))
    part "web/2026-11-20/b.log", "2026-11-20T10:00:00.000000002Z b1"

    expect(shown(day("2026-11-20"))).to eq %w[a1 b1]
    expect(shown(day("2026-11-20"))).to eq %w[a1 b1]
    expect(Logsafe.storage).to have_received(:fetch).twice
  end

  it "deletes its copy of a day that nobody looked at for half an hour" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    shown(day("2026-11-20"))
    expect(Dir.children(copies).map { |name| File.extname(name) }).to contain_exactly(".keys", ".lock", ".log")

    Logsafe::Copies.sweep
    expect(Dir.children(copies).size).to eq 3

    FileUtils.mkdir(File.join(copies, "abc123.left-by-a-search-that-was-cut-off"))
    Dir.children(copies).each { |name| File.utime(Time.now - 1801, Time.now - 1801, File.join(copies, name)) }
    Logsafe::Copies.sweep
    expect(Dir.children(copies).map { |name| File.extname(name) }.uniq).to eq [".lock"]
    expect(shown(day("2026-11-20"))).to eq ["a1"]
  end

  it "deletes every copy when the process ends" do
    at_the_end = nil
    allow(Logsafe::Copies).to receive(:at_exit) { |&block| at_the_end = block }
    Logsafe::Copies.instance_variable_set(:@sweeper, nil) # as in a process that has not searched yet
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    shown(day("2026-11-20"))

    at_the_end.call
    expect(Dir.children(copies).map { |name| File.extname(name) }).to eq [".lock"]
  end

  it "goes on from where a fetch was cut off" do
    stub_const("Logsafe::Copies::SLICE", 1)
    allow(Logsafe.storage).to receive(:fetch).and_call_original
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    part "web/2026-11-20/b.log.gz", "not gzip"
    File.binwrite(File.join(root, "parts/web/2026-11-20/b.log.gz"), "\x1F\x8Bbroken".b)
    File.utime(Time.now - 600, Time.now - 600, File.join(root, "parts/web/2026-11-20/b.log.gz"))
    expect(get(day("2026-11-20")).last).to include "b.log.gz cannot be read"

    part "web/2026-11-20/b.log.gz", "2026-11-20T10:00:00.000000002Z b1"

    expect(shown(day("2026-11-20"))).to eq %w[a1 b1]
    expect(Logsafe.storage).to have_received(:fetch).exactly(3).times # a once, b twice
  end

  it "says so when another search is fetching the same day, and does not wait for it" do
    stub_const("Logsafe::Copies::WAIT", 0)
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    shown(day("2026-11-20"))

    File.open(Dir.glob(File.join(copies, "*.lock")).first) do |other|
      other.flock(File::LOCK_EX)
      expect(get(day("2026-11-20")).last).to include "another search is fetching these logs"
    end
    expect(shown(day("2026-11-20"))).to eq ["a1"]
  end

  it "says so when the merge job removed a part while it was read" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    allow(Logsafe.storage).to receive(:fetch) do
      FileUtils.rm_rf(File.join(root, "parts"))
      raise Errno::ENOENT
    end

    expect(get(day("2026-11-20")).last).to include "the storage changed while it was read"
  end

  it "leaves an error of the storage to the app" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    allow(Logsafe.storage).to receive(:fetch).and_raise(IOError, "network")

    expect { get(day("2026-11-20")) }.to raise_error(IOError)
  end

  it "keeps the logs of two storages apart" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z here"
    shown(day("2026-11-20"))
    other = Dir.mktmpdir("logsafe-spec")
    FileUtils.mkdir_p(File.join(other, "parts/web/2026-11-20"))
    File.write(File.join(other, "parts/web/2026-11-20/a.log"), "2026-11-20T10:00:00.000000001Z there\n")
    File.utime(Time.now - 600, Time.now - 600, File.join(other, "parts/web/2026-11-20/a.log"))

    Logsafe.storage = other

    expect(shown(day("2026-11-20"))).to eq ["there"]
  ensure
    FileUtils.rm_rf(other)
  end

  it "searches a week at most, and says so" do
    part "web/2026-11-10/a.log", "2026-11-10T10:00:00.000000001Z too far back"
    part "web/2026-11-14/a.log", "2026-11-14T10:00:00.000000001Z in reach"

    page = get(from: "2026-11-01", to: "2026-11-20").last

    expect(page).to include "A search spans 7 days at most, so this one starts on 2026-11-14."
    expect(shown(from: "2026-11-01", to: "2026-11-20")).to eq ["in reach"]
  end

  context "with a key" do
    let(:key) { Logsafe.generate_key }

    before do
      Logsafe.key = key
      line_key = Logsafe::Cipher.day_keys(Logsafe.keys, "web", "2026-11-20").first
      part "web/2026-11-20/a.log", Logsafe::Cipher.seal_line("2026-11-20T10:00:00.000000001Z a1", line_key)
      2.times { Logsafe.merge(today: "2026-11-22") } # now an encrypted file
      part "web/2026-11-20/late.log", Logsafe::Cipher.seal_line("2026-11-20T10:00:00.000000002Z a2", line_key)
    end

    it "reads the encrypted file and the encrypted lines" do
      expect(shown(day("2026-11-20"))).to eq %w[a1 a2]
    end

    it "says which stream it cannot read without the key, and shows the others" do
      Logsafe.key = nil
      part "worker/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z w1"

      page = get(day("2026-11-20")).last

      expect(page).to include "web 2026-11-20: this is encrypted and Logsafe.key is not set"
      expect(shown(day("2026-11-20"))).to eq ["w1"]
    end
  end
end

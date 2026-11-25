# frozen_string_literal: true

RSpec.describe Logsafe do
  let(:root) { Dir.mktmpdir("logsafe-spec") }

  before do
    described_class.storage = root
    allow(described_class).to receive(:warn)
  end

  after do
    described_class.streams = nil
    FileUtils.rm_rf(root)
  end

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

  context "when whoever writes the parts means harm" do
    it "leaves out a part that unpacks to more than any part has reason to" do
      stub_const("Logsafe::Source::PART_LIMIT", 1 << 20)
      part "web/2026-11-20/bomb.log.gz", "2026-11-20T10:00:00.000000001Z #{"a" * (2 << 20)}", gzip: true
      part "web/2026-11-20/good.log", "2026-11-20T10:00:00.000000002Z good"

      expect { merge }.to raise_error(Logsafe::Error, /bomb.log.gz: cannot be read: .* more than 1 MB/)
      expect(day_file("web", "2026-11-20")).to eq ["2026-11-20T10:00:00.000000002Z good"]
    end

    it "leaves out a part with a line that is too long" do
      stub_const("Logsafe::Source::LINE_LIMIT", 1 << 20)
      part "web/2026-11-20/long.log", "2026-11-20T10:00:00.000000001Z #{"a" * (2 << 20)}"
      part "web/2026-11-20/good.log", "2026-11-20T10:00:00.000000002Z good"

      expect { merge }.to raise_error(Logsafe::Error, /long.log: a line is longer than 1 MB/)
      expect(day_file("web", "2026-11-20").size).to eq 1
    end

    it "does not fill the disk" do
      allow(Logsafe::Room).to receive(:free).and_return(40)
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"

      expect { merge }.to raise_error(Logsafe::Full, /too little room/)
      expect(files).to eq ["parts/web/2026-11-20/a.log"]
    end

    it "gives a line whose time is not of its day the start of that day" do
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1", "2026-11-19T10:00:00.000000001Z yesterday",
           "~ no time", "2026-11-20T10:00:00.000000002Z \xFF".b

      merge

      expect(day_file("web", "2026-11-20").map(&:b)).to eq [
        "2026-11-20T00:00:00.000000000Z 2026-11-19T10:00:00.000000001Z yesterday",
        "2026-11-20T00:00:00.000000000Z ~ no time", "2026-11-20T10:00:00.000000001Z a1",
        "2026-11-20T10:00:00.000000002Z \xFF".b
      ]
    end

    it "passes by what is not a stream's name or not a date, and says how many" do
      part "web/2026-02-30/a.log", "no such day"
      part "web\nI forged/2026-11-20/a.log", "a name with a line break"
      part "#{"x" * 201}/2026-11-20/a.log", "too long for the day's file"
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"

      2.times { merge }

      expect(files.grep_v(/parts/)).to eq ["2026/11/web.2026-11-20.log.gz"]
      expect(parts.size).to eq 3
      expect(described_class).to have_received(:warn).with(/leaves 3 files under parts. alone/).twice
    end
  end

  context "when someone makes up streams and days" do
    before do
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
      part "made-up/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z x"
      part "web/2025-11-20/a.log", "2025-11-20T10:00:00.000000001Z too long ago"
    end

    it "merges only the streams there are, when it was told which" do
      described_class.streams = %w[web worker]

      2.times { merge }

      expect(files).to eq ["2026/11/web.2026-11-20.log.gz", "parts/made-up/2026-11-20/a.log",
                           "parts/web/2025-11-20/a.log"]
      expect(described_class).to have_received(:warn).with(/leaves 2 files .* Not in Logsafe.streams: made-up/).twice
    end

    it "goes back a year and no further" do
      2.times { merge }

      expect(parts).to eq ["parts/web/2025-11-20/a.log"]
      expect(described_class).to have_received(:warn).with(/leaves 1 files under parts. alone/).twice
    end

    it "leaves what it has no time for to the next run" do
      stub_const("Logsafe::RUN", 0)
      merge
      expect(files.grep_v(/parts/)).to eq []
      expect(described_class).to have_received(:warn).with(/leaves 2 days to the next run/)

      stub_const("Logsafe::RUN", 60)
      merge
      expect(files.grep_v(/parts/).size).to eq 2
    end

    it "does not take a list of streams that would leave out everything" do
      expect { described_class.streams = [] }.to raise_error(Logsafe::Error, /is empty/)
      expect { described_class.streams = ["web", "a/b"] }.to raise_error(Logsafe::Error, %r{"a/b"})
    end
  end

  it "keeps every line when several runs merge at the same time, while parts arrive" do
    stub_const("Logsafe::Storage::Folder::SETTLE", 0)
    30.times do |number|
      part "web/2026-11-20/#{number}.log", "2026-11-20T10:00:00.#{number.to_s.rjust(9, "0")}Z #{number}"
      Array.new(3) { Thread.new { described_class.merge(today: "2026-11-22") rescue nil } }.each(&:join) # rubocop:disable Style/RescueModifier
    end
    3.times { merge }

    expect(day_file("web", "2026-11-20").map { |line| line.split.last.to_i }).to eq (0..29).to_a
    expect(parts).to eq []
  end

  it "does not put an older file in place of one that another run wrote meanwhile" do
    part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
    2.times { merge }
    part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"
    newer = Zlib.gzip("2026-11-20T10:00:00.000000001Z a1\n2026-11-20T10:00:00.000000003Z newer\n")
    read = 0
    allow(described_class.storage).to receive(:fetch).and_wrap_original do |fetch, key, path|
      fetch.call(key, path)
      File.binwrite(day_path("web", "2026-11-20"), newer) if key.end_with?(".log.gz") && (read += 1) == 1
    end

    merge
    expect(day_file("web", "2026-11-20").last).to end_with "newer"

    2.times { merge }
    expect(day_file("web", "2026-11-20").map { |line| line.split.last }).to eq %w[a1 late newer]
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
      expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz: cannot be read/)
      expect(described_class).to have_received(:warn).with(/could not merge web 2026-11-20/)
    end

    it "merges that day's other parts, and leaves the one it could not read where it is" do
      2.times { expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz: cannot be read/) }

      expect(day_file("web", "2026-11-20").map { |line| line.split.last }).to eq %w[a1 late]
      expect(parts.grep(/web/)).to eq ["parts/web/2026-11-20/broken.log.gz", "parts/web/2026-11-21/a.log"].first(1)
    end

    it "does the same when the storage will not give a part" do
      allow(described_class.storage).to receive(:fetch).and_call_original
      allow(described_class.storage).to receive(:fetch).with(/broken/, anything).and_raise(IOError, "archived")

      expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz: IOError: archived/)
      expect(day_file("web", "2026-11-20").map { |line| line.split.last }).to eq %w[a1 late]
    end

    it "fails the day when it is the day's own file, and changes nothing" do
      FileUtils.rm(File.join(root, "parts/web/2026-11-20/broken.log.gz"))
      File.binwrite(day_path("web", "2026-11-20"), "#{Logsafe::GZIP}this is not gzip")

      expect { merge }.to raise_error(Logsafe::Error, /cannot be read/)
      expect(File.binread(day_path("web", "2026-11-20"))).to eq "#{Logsafe::GZIP}this is not gzip".b
      expect(parts).to include("parts/web/2026-11-20/late.log")
    end

    it "still merges the other days and streams" do
      expect { merge }.to raise_error(Logsafe::Error, /broken.log.gz: cannot be read/)

      expect(day_file("web", "2026-11-21")).to eq ["2026-11-21T00:00:00.000000000Z next day"]
      expect(day_file("worker", "2026-11-20")).to eq ["2026-11-20T10:00:00.000000001Z w1"]
    end
  end

  context "with a key" do
    let(:key) { described_class.generate_key }
    let(:enc) { "2026/11/web.2026-11-20.log.gz.enc" }
    let(:command) do
      [RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), File.expand_path("../exe/logsafe", __dir__)]
    end

    before { described_class.key = key }

    after do
      described_class.key = nil
      described_class.old_keys = nil
    end

    # A line as shipper/vector.yaml encrypts it.
    def sealed(line, with: key)
      cipher = OpenSSL::Cipher.new("chacha20-poly1305").encrypt
      cipher.key = OpenSSL::HMAC.digest("SHA256", with.unpack1("m"), "web/#{line[0, 10]}")
      nonce = cipher.random_iv
      "enc:#{[nonce + cipher.update(line) + cipher.final + cipher.auth_tag].pack("m0")}"
    end

    def decrypted(file = enc)
      Dir.mktmpdir do |dir|
        described_class.decrypt(File.join(root, file), File.join(dir, "day.gz"))
        Zlib.gunzip(File.binread(File.join(dir, "day.gz"))).lines(chomp: true)
      end
    end

    it "encrypts the day's file, and the key opens it again" do
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000002Z a2", "2026-11-20T10:00:00.000000001Z a1"

      2.times { merge }

      expect(files).to eq [enc]
      expect(File.binread(File.join(root, enc))).to start_with("logsafe1")
      expect(decrypted).to eq ["2026-11-20T10:00:00.000000001Z a1", "2026-11-20T10:00:00.000000002Z a2"]
    end

    it "reads the lines the shipper encrypted, and keeps a line once when it was encrypted twice" do
      part "web/2026-11-20/a.log.gz", sealed("2026-11-20T10:00:00.000000003Z a3"),
           sealed("2026-11-20T10:00:00.000000001Z a1"), gzip: true
      part "web/2026-11-20/again.log", sealed("2026-11-20T10:00:00.000000001Z a1")
      part "web/2026-11-20/plain.log", "2026-11-20T10:00:00.000000002Z from before the key"

      2.times { merge }

      expect(files).to eq [enc]
      expect(decrypted.map { |line| line.split.last }).to eq %w[a1 key a3]
    end

    it "takes the plain file of a day in, once the key is set" do
      described_class.key = nil
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
      merge
      described_class.key = key
      part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"

      2.times { merge }

      expect(files).to eq [enc]
      expect(decrypted.map { |line| line.split.last }).to eq %w[a1 late]
    end

    it "encrypts what was plain before the key was set: a day's file, and the lines of a part" do
      stub_const("Logsafe::Storage::Folder::SETTLE", 0)
      described_class.key = nil
      part "web/2026-11-19/a.log", "2026-11-19T10:00:00.000000001Z before"
      2.times { merge }
      part "web/2026-11-20/a.log.gz", "2026-11-20T10:00:00.000000001Z a1", "", gzip: true
      part "stray", "not a part: the merge passes it by, and so must this"
      described_class.key = key

      described_class.reencrypt

      expect(files).to eq ["2026/11/web.2026-11-19.log.gz.enc", "parts/stray", "parts/web/2026-11-20/a.log.gz"]
      expect(decrypted(files.first)).to eq ["2026-11-19T10:00:00.000000001Z before"]
      expect(Zlib.gunzip(File.binread(File.join(root, files.last)))).to match(/\Aenc:\S+\n\n\z/)
      2.times { merge }
      expect(decrypted).to eq ["2026-11-20T10:00:00.000000001Z a1"]
    end

    it "encrypts a plain line as it is, to its last byte" do
      stub_const("Logsafe::Storage::Folder::SETTLE", 0)
      part "web/2026-11-20/a.log", text: "2026-11-20T10:00:00.000000001Z from a terminal\r\n"

      described_class.reencrypt

      line_keys = Logsafe::Cipher.day_keys(described_class.keys, "web", "2026-11-20")
      expect(Logsafe::Cipher.plain(File.read(File.join(root, parts.first)), line_keys))
        .to eq "2026-11-20T10:00:00.000000001Z from a terminal\r\n"
    end

    context "when the key is changed" do
      let(:new_key) { described_class.generate_key }

      before do
        part "web/2026-11-20/a.log", sealed("2026-11-20T10:00:00.000000001Z a1")
        2.times { merge }
        part "web/2026-11-20/late.log", sealed("2026-11-20T10:00:00.000000002Z old"),
             sealed("2026-11-20T10:00:00.000000003Z new", with: new_key)
        described_class.key = new_key
      end

      it "reads what the old key encrypted, and writes it again with the new one" do
        described_class.old_keys = ", #{described_class.generate_key},#{key}\n"

        2.times { merge }
        described_class.old_keys = nil

        expect(files).to eq [enc]
        expect(decrypted.map { |line| line.split.last }).to eq %w[a1 old new]
      end

      context "when everything is encrypted again" do
        def stored
          files.to_h { |name| [name, File.binread(File.join(root, name))] }
        end

        before do
          stub_const("Logsafe::Storage::Folder::SETTLE", 0)
          allow(Logsafe::Reencrypt).to receive(:warn)
          Logsafe::ReencryptJob.logger = Logger.new(nil)
          Logsafe::ReencryptJob.queue_adapter = :inline
          part "web/2026-11-20/z.log.gz", sealed("2026-11-20T10:00:00.000000004Z gz"), "plain", gzip: true
        end

        it "needs the old key no more, in the day's file or in the parts" do
          described_class.old_keys = key
          Logsafe::ReencryptJob.perform_later
          described_class.old_keys = nil

          expect(decrypted.size).to eq 1
          2.times { merge }
          expect(files).to eq [enc]
          expect(decrypted.map { |line| line.split.last }).to eq %w[plain a1 old new gz]
        end

        it "does not put a file back as it was before a merge that came in between" do
          described_class.old_keys = key
          allow(described_class.storage).to receive(:fetch).and_wrap_original do |fetch, name, path|
            fetch.call(name, path)
            FileUtils.touch(File.join(root, name)) if name.end_with?(".enc") # as a merge would have
          end

          expect { described_class.reencrypt }.to raise_error(Logsafe::Storage::Changed, /changed meanwhile/)
        end

        it "encrypts only the streams there are, when it was told which" do
          described_class.old_keys = key
          described_class.streams = ["worker"]
          before = stored

          described_class.reencrypt
          expect(stored).to eq before
        end

        it "leaves what the new key opens as it is, when run again" do
          described_class.old_keys = key
          described_class.reencrypt
          before = stored

          described_class.reencrypt

          expect(stored).to eq before
        end

        it "fails without the old key, and changes nothing" do
          before = stored

          expect { described_class.reencrypt }.to raise_error(Logsafe::Error, /not encrypted with this key or an old/)
          expect(stored).to eq before
          expect(Logsafe::Reencrypt).to have_received(:warn).with(/could not encrypt #{enc}/)
        end
      end

      it "fails without the old key, and keeps the file and the part" do
        expect { merge }.to raise_error(Logsafe::Error, /not encrypted with this key or an old one/)
        expect(files).to eq [enc, "parts/web/2026-11-20/late.log"]
      end

      it "reads a file of the old key from the command line" do
        gzip, = Open3.capture2({ "LOGSAFE_KEY" => new_key, "LOGSAFE_OLD_KEYS" => key }, *command, "decrypt",
                               File.join(root, enc), binmode: true)

        expect(Zlib.gunzip(gzip)).to eq "2026-11-20T10:00:00.000000001Z a1\n"
      end
    end

    context "when the day's file cannot be opened" do
      before do
        part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
        2.times { merge }
        part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"
      end

      it "fails with another key, and keeps the file and the part" do
        described_class.key = described_class.generate_key

        expect { merge }.to raise_error(Logsafe::Error, /not encrypted with this key/)
        expect(files).to eq [enc, "parts/web/2026-11-20/late.log"]

        described_class.key = key
        expect(decrypted.size).to eq 1
      end

      it "fails when the file has been changed" do
        File.open(File.join(root, enc), "r+b") { |file| file.pwrite("x", file.size / 2) }

        expect { merge }.to raise_error(Logsafe::Error, /has been changed/)
        expect(files).to eq [enc, "parts/web/2026-11-20/late.log"]
      end

      # Old keys alone must not open it, or the merge would write the day again in plain text.
      it "fails without the key, also when it is still among the old ones" do
        described_class.key = nil
        described_class.old_keys = key

        expect { merge }.to raise_error(Logsafe::Error, /Logsafe.key is not set/)
        expect(files).to eq [enc, "parts/web/2026-11-20/late.log"]
      end
    end

    it "fails on a line that was encrypted with another key, and keeps the part" do
      part "web/2026-11-20/a.log", sealed("2026-11-20T10:00:00.000000001Z a1", with: described_class.generate_key)

      expect { merge }.to raise_error(Logsafe::Error, /a line was not encrypted with this key/)
      expect(files).to eq ["parts/web/2026-11-20/a.log"]
    end

    it "opens a line only when nothing follows its end" do
      line_keys = Logsafe::Cipher.day_keys(described_class.keys, "web", "2026-11-20")
      first, second = %w[a1x a2x].map { |text| sealed("2026-11-20T10:00:00.000000001Z #{text}") }
      expect(first).to end_with "=" # so that there is an end to write behind

      expect(Logsafe::Cipher.plain("#{first}\n", line_keys)).to end_with "a1x\n"
      expect { Logsafe::Cipher.plain("#{first}#{second}\n", line_keys) }.to raise_error(Logsafe::Error)
    end

    it "does not take a line that holds a line break, or let one that says enc: be decrypted twice" do
      part "web/2026-11-20/a.log", sealed("2026-11-20T10:00:00.000000001Z a1\nenc:junk")
      part "web/2026-11-20/b.log", Logsafe::Cipher.seal_line(
        "enc:junk", Logsafe::Cipher.day_keys(described_class.keys, "web", "2026-11-20").first
      )

      2.times { expect { merge }.to raise_error(Logsafe::Error, /a.log: an encrypted line holds a line break/) }
      expect(decrypted).to eq ["2026-11-20T00:00:00.000000000Z enc:junk"]
      expect(parts).to eq ["parts/web/2026-11-20/a.log"]
    end

    context "when someone without the key changes the storage" do
      before do
        part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
        part "web/2026-11-21/a.log", "2026-11-21T10:00:00.000000001Z another day"
        2.times { merge }
        part "web/2026-11-20/late.log", "2026-11-20T10:00:00.000000002Z late"
      end

      it "does not take a plain file for the encrypted one" do
        File.binwrite(File.join(root, enc), Zlib.gzip("2026-11-20T10:00:00.000000001Z made up\n"))

        expect { merge }.to raise_error(Logsafe::Error, /not encrypted with this key/)
      end

      it "does not take another day's file for this one's" do
        FileUtils.cp(File.join(root, enc.sub("20.log", "21.log")), File.join(root, enc))

        expect { merge }.to raise_error(Logsafe::Error, %r{the file of "web/2026-11-21", not of web/2026-11-20})
      end

      it "does not take an encrypted file for a part" do
        FileUtils.cp(File.join(root, enc.sub("20.log", "21.log")), File.join(root, "parts/web/2026-11-20/x.log"))
        merge

        expect(decrypted.map { |line| line.split.last }).to include("late")
        expect(decrypted.join).not_to include("another day")
      end

      it "does not tell them how well the lines compress" do
        part "web/2026-11-20/guess.log", "2026-11-20T10:00:00.000000002Z #{"late" * 500}"
        before = File.size(File.join(root, enc))
        merge

        expect(File.size(File.join(root, enc))).to eq before
      end
    end

    it "does not take a key that is not one" do
      ["secret", "c2VjcmV0", "#{"A" * 42}B="].each do |text|
        expect { described_class.key = text }.to raise_error(Logsafe::Error, /32 bytes in Base64/)
        expect { described_class.old_keys = text }.to raise_error(Logsafe::Error, /32 bytes in Base64/)
      end
    end

    it "is made and used from the command line" do
      part "web/2026-11-20/a.log", "2026-11-20T10:00:00.000000001Z a1"
      made, = Open3.capture2(*command, "key")
      described_class.key = made

      merge
      gzip, status = Open3.capture2({ "LOGSAFE_KEY" => made }, *command, "decrypt", File.join(root, enc), binmode: true)
      _, wrong = Open3.capture2e({ "LOGSAFE_KEY" => key }, *command, "decrypt", File.join(root, enc))
      part "web/2026-11-22/1.log", text: sealed("2026-11-22T08:00:00.000000000Z first", with: made)
      part "web/2026-11-22/2.log.gz", sealed("2026-11-22T08:00:00.000000001Z second", with: made), gzip: true
      part "web/2026-11-22/3.log", "enc:junk"
      today, part_left_out = Open3.capture2({ "LOGSAFE_KEY" => made }, *command, "decrypt", "web", "2026-11-22",
                                            *files.grep(/2026-11-22/).map { |name| File.join(root, name) }, err: File::NULL)

      expect(status).to be_success
      expect(Zlib.gunzip(gzip)).to eq "2026-11-20T10:00:00.000000001Z a1\n"
      expect(wrong).not_to be_success
      expect(today).to eq "2026-11-22T08:00:00.000000000Z first\n2026-11-22T08:00:00.000000001Z second\n"
      expect(part_left_out).not_to be_success
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

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
      expect(decrypted).to eq ["", "2026-11-20T10:00:00.000000001Z a1"]
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
        let(:stored) { files.to_h { |name| [name, File.binread(File.join(root, name))] } }

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
          expect(decrypted.map { |line| line.split.last }).to eq %w[a1 old new gz plain]
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
      today, = Open3.capture2({ "LOGSAFE_KEY" => made }, *command, "decrypt", "web", "2026-11-22",
                              stdin_data: "#{sealed("2026-11-22T08:00:00.000000000Z today", with: made)}\nplain\n")

      expect(status).to be_success
      expect(Zlib.gunzip(gzip)).to eq "2026-11-20T10:00:00.000000001Z a1\n"
      expect(wrong).not_to be_success
      expect(today).to eq "2026-11-22T08:00:00.000000000Z today\nplain\n"
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

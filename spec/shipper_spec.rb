# frozen_string_literal: true

require "open3"
require "securerandom"

# The whole path, for each kind of storage: containers write, Docker rotates a log file, Vector is
# restarted on the way, and the merge job must end up with one complete, sorted file.
# Needs Docker, and the network and stand-ins that shipper/test starts.
RSpec.describe "from Docker through Vector to one file a day",
               skip: ("needs Docker, run shipper/test" unless ENV["LOGSAFE_TEST_VECTOR"]) do
  let(:config) { Dir.mktmpdir("logsafe-vector") }
  let(:shipper) { File.expand_path("../shipper", __dir__) }
  let(:run_options) { [] }
  let(:suffix) { "" }
  let(:part_line) { /\A\d{4}-\d{2}-\d{2}T/ }

  before { stub_const("Logsafe::Storage::Folder::SETTLE", 0) }

  after do
    docker "rm", "-f", *docker("ps", "-aq", "--filter", "label=logsafe-e2e").split
    FileUtils.rm_rf(config)
  end

  # What docker printed, without its remarks: on a machine that has to pull the image first, the
  # pulling would end up in the container's id.
  def docker(*arguments)
    output, remarks, status = Open3.capture3("docker", *arguments)
    status.success? ? output.strip : raise("docker #{arguments.join(" ")}: #{remarks}#{output}")
  end

  def writer(text, *options)
    docker "create", "--label", "logsafe-e2e", *options, "alpine", "sh", "-c",
           "for i in $(seq 1 150); do echo #{text} $i; sleep 0.02; done"
  end

  # The repository's own config, with its file pattern narrowed to these containers so that no other
  # logs on this machine are read, and the sink pointed at the stand-in.
  def configure(sink, containers, changes)
    main = File.read(File.join(shipper, "vector.yaml"))
    pattern = main[%r{/var/lib/docker/containers/\*/[^"]*}] || raise("no include pattern in vector.yaml")
    include = containers.map { |id| pattern.sub("*", id).inspect }.join(", ")
    File.write(File.join(config, "vector.yaml"), main.sub(/include: .*/, "include: [#{include}]"))

    text = File.read(File.join(shipper, sink))
    changes.each { |from, to| text.sub!(from, to) || raise("#{from.inspect} is not in #{sink}") }
    File.write(File.join(config, "sink.yaml"), text)
    FileUtils.cp(File.join(shipper, "start"), config)
  end

  # { key of a part => its lines }
  def parts
    Dir.mktmpdir do |dir|
      Logsafe.storage.keys("parts/e2e/").to_h do |key|
        Logsafe.storage.fetch(key, File.join(dir, "part"))
        data = File.binread(File.join(dir, "part"))
        [key, (data.start_with?(Logsafe::GZIP) ? Zlib.gunzip(data) : data).lines]
      end
    end
  end

  def part_lines
    parts.values.flatten
  end

  # Counted by what the lines say: a line that Vector read twice is encrypted differently each time.
  def shipped
    parts.flat_map do |key, lines|
      line_keys = Logsafe::Cipher.day_keys(Logsafe.keys, *key.split("/")[1, 2])
      lines.map { |line| Logsafe::Cipher.plain(line, line_keys) }
    end.uniq.size
  end

  def read(key)
    Dir.mktmpdir do |dir|
      Logsafe.storage.fetch(key, day = File.join(dir, "day"))
      day = Logsafe.decrypt(day, "#{day}.gz") if key.end_with?(".enc")
      Zlib.gunzip(File.binread(day)).lines(chomp: true)
    end
  end

  def ship(sink, changes)
    a = writer("a", "--label", "logs=e2e", "--log-opt", "labels=logs", "--log-opt", "max-size=4k",
               "--log-opt", "max-file=10")
    b = writer("b", "--label", "logs=e2e", "--log-opt", "labels=logs")
    noise = writer("noise")
    configure(sink, [a, b, noise], changes)
    vector = docker "run", "-d", "--label", "logsafe-e2e", "--network", "logsafe-test", *run_options,
                    "-v", "#{config}:/etc/vector:ro", "-v", "/var/lib/vector",
                    "-v", "/var/lib/docker/containers:/var/lib/docker/containers:ro", "--entrypoint", "sh",
                    ENV.fetch("LOGSAFE_TEST_VECTOR"), "/etc/vector/start",
                    "--config", "/etc/vector/vector.yaml", "--config", "/etc/vector/sink.yaml"

    docker "start", a, b, noise
    sleep 1
    docker "restart", vector # the writers carry on meanwhile
    docker "wait", a, b, noise
    rotated = docker("run", "--rm", "-v", "/var/lib/docker/containers:/c:ro", "alpine", "sh", "-c",
                     "ls /c/#{a}/*-json.log* | wc -l").to_i
    raise "the log file was not rotated, so rotation is not checked" unless rotated > 1

    60.times do
      settle
      shipped == 300 ? break : sleep(1)
    end
    return docker("stop", vector) if shipped == 300

    logs, = Open3.capture2e("docker", "logs", "--tail", "20", vector) # both streams: Vector's log is on either
    raise "Vector shipped #{shipped} of 300 lines:\n#{logs}"
  end

  shared_examples "shipping" do |sink|
    it "ends with one complete, sorted file" do
      Logsafe.storage = storage
      ship(sink, changes)
      settle
      expect(part_lines).to all(match(part_line))

      2.times { Logsafe.merge("e2e", today: (Time.now.utc + (2 * 86_400)).strftime("%F")) }

      days = Logsafe.storage.keys("")
      expect(days).to all(match(%r{\A\d{4}/\d{2}/e2e\.\d{4}-\d{2}-\d{2}\.log\.gz#{suffix}\z}))
      expect(days.size).to be_between(1, 2) # two if the run crossed midnight UTC
      lines = days.sort.flat_map { |key| read(key) }
      expect(lines).to all(match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z [ab] \d+\z/))
      expect(lines).to eq lines.sort
      %w[a b].each do |who|
        numbers = lines.map(&:split).select { |_, name, _| name == who }.map { |_, _, number| number.to_i }
        expect(numbers).to eq((1..150).to_a), "#{who}: missing #{(1..150).to_a - numbers}, " \
                                              "twice #{numbers.tally.select { |_, count| count > 1 }.keys}, " \
                                              "order #{numbers.each_cons(2).reject { |one, two| one < two }}"
      end
    end
  end

  def settle; end

  context "with S3" do
    let(:options) do
      { endpoint: ENV.fetch("LOGSAFE_TEST_S3"), force_path_style: true, region: "us-east-1",
        access_key_id: "test", secret_access_key: "test" }
    end
    let(:bucket) { "e2e-#{SecureRandom.hex(4)}" }
    let(:storage) do
      require "aws-sdk-s3"
      Aws::S3::Resource.new(**options).create_bucket(bucket:)
      Logsafe::Storage.build(s3: bucket, **options)
    end
    let(:run_options) { %w[-e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test] }
    let(:changes) do
      { "bucket: my-logs" => "bucket: #{bucket}", /# endpoint: .*/ => "endpoint: http://logsafe-test-s3:7070",
        "timeout_secs: 60" => "timeout_secs: 2" }
    end

    it_behaves_like "shipping", "to-s3.yaml"

    # What Vector encrypts, line by line, the merge job has to open with the same key.
    context "when encrypted" do
      let(:key) { Logsafe.generate_key }
      let(:run_options) { super() + ["-e", "LOGSAFE_KEY=#{key}"] }
      let(:suffix) { ".enc" }

      before { Logsafe.key = key }
      after { Logsafe.key = nil }

      let(:part_line) { /\Aenc:/ } # nothing readable in the storage

      it_behaves_like "shipping", "to-s3.yaml"
    end
  end

  # Not Google Cloud Storage: the local stand-in refuses the kind of upload Vector makes, so
  # to-gcs.yaml is only checked for validity, and the storage itself in storage_spec.rb.

  context "with a folder" do
    let(:folder) { Dir.mktmpdir("logsafe-folder") }
    let(:storage) { Logsafe::Storage.build(folder) }
    let(:run_options) { ["-v", "#{folder}:/logs"] }
    let(:changes) { {} }

    after { FileUtils.rm_rf(folder) }

    # Vector writes as root; let this process remove the files, as the README's setup does on a server.
    def settle
      docker "run", "--rm", "-v", "#{folder}:/logs", "alpine", "chmod", "-R", "a+rwX", "/logs"
    end

    it_behaves_like "shipping", "to-folder.yaml"
  end
end

# Vector would start with any key, and then drop the lines it could not encrypt.
RSpec.describe "shipper/start", skip: ("needs Docker, run shipper/test" unless ENV["LOGSAFE_TEST_VECTOR"]) do
  def start(key)
    Open3.capture2e("docker", "run", "--rm", "-e", "LOGSAFE_KEY=#{key}",
                    "-v", "#{File.expand_path("../shipper", __dir__)}:/etc/vector:ro", "--entrypoint", "sh",
                    ENV.fetch("LOGSAFE_TEST_VECTOR"), "/etc/vector/start", "--version")
  end

  it "does not start Vector with a key that is not one" do
    not_keys = ["secret", "c2VjcmV0", Logsafe.generate_key[0, 43], "\"#{Logsafe.generate_key}\"",
                "#{Logsafe.generate_key},", "#{"A" * 42}B="] # the last decodes for some, but not for Vector
    not_keys.each do |key|
      output, status = start(key)
      expect(status).not_to be_success, "started with #{key.inspect}"
      expect(output).to match(/LOGSAFE_KEY is not a key.*Vector was not started/)
    end
  end

  it "starts Vector with a key, and without one" do
    [Logsafe.generate_key, ""].each { |key| expect(start(key).first).to start_with("vector 0.62") }
  end
end

# frozen_string_literal: true

require "active_support"
require "active_support/logger"
require "active_support/broadcast_logger"
require "fileutils"

RSpec.describe Logsafe::Development do
  let(:root) { Dir.mktmpdir }
  let(:logs) { described_class.new(root, "rails") }
  let(:logger) { ActiveSupport::Logger.new(logs, formatter: Logger::Formatter.new) }
  let(:today) { Time.now.utc.strftime("%F") }

  around do |example|
    before = Logsafe.instance_variable_get(:@storage)
    example.run
  ensure
    Logsafe.instance_variable_set(:@storage, before)
    Logsafe.streams = nil
    FileUtils.rm_rf(root)
  end

  def page(query = "")
    Logsafe::Web.call("REQUEST_METHOD" => "GET", "QUERY_STRING" => query)[2].join
  end

  it "shows what was logged at once, each time, the lines of a message in order and without colours" do
    Logsafe.storage = logs
    logger.error("\e[1mzebra\e[0m came first\n\nthen the ape")
    expect(page).to match(/ERROR -- : zebra came first.*then the ape/m)
    logger.info("all is well \xFF")
    expect(page).to match(/zebra came first.*then the ape.*all is well/m)
    expect(page).not_to include("\e")
    expect(page("level=error")).not_to include("all is well")
  end

  it "keeps the lines of two programs apart" do
    Logsafe.storage = logs
    logs.write("one\n")
    described_class.new(root, "sidekiq").write("two\n")
    streams = logs.keys("parts/").map { |key| key.split("/")[1, 2] }
    expect(streams).to contain_exactly(["rails", today], ["sidekiq", today])
  end

  it "is for this user only" do
    logs.write("one\n")
    path = File.join(root, logs.keys("parts/").first)
    expect([File.stat(path).mode & 0o077, File.stat(File.dirname(path)).mode & 0o077]).to eq([0, 0])
  end

  it "deletes the days that are too old when it starts, and nothing else" do
    old = (Time.now.utc.to_date - 3).to_s
    kept = (Time.now.utc.to_date - 2).to_s
    dirs = ["parts/rails/#{old}", "parts/rails/#{kept}", "open/#{old}", "parts/rails/notes", "2020/01"]
    dirs.each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
    described_class.start(root, ActiveSupport::BroadcastLogger.new(Logger.new(IO::NULL)), program: "bin/rails")
    expect(dirs.select { |dir| File.directory?(File.join(root, dir)) })
      .to eq(["parts/rails/#{kept}", "parts/rails/notes", "2020/01"])
  end

  it "names the stream after the program, and lets no names of containers hide it" do
    Logsafe.streams = %w[shop-prod-web]
    logger = ActiveSupport::BroadcastLogger.new(Logger.new(IO::NULL))
    described_class.start(root, logger, program: "/app/bin/jobs: worker")
    logger.warn("hello")
    expect(page).to include("hello", "jobs")
  end

  # A Rails app of its own, in a process of its own.
  describe "in a Rails app" do
    def app(env, setting = "")
      File.write(File.join(root, "app.rb"), <<~RUBY)
        require "rails"
        require "logsafe"
        class App < Rails::Application
          config.root = #{root.inspect}
          config.eager_load = false
          config.secret_key_base = "x" * 64
        end
        #{setting}
        App.initialize!
        Rails.logger.error("it broke")
        Rails.logger.silence { Rails.logger.info("not said") }
        puts Logsafe::Web.call("REQUEST_METHOD" => "GET", "QUERY_STRING" => "")[2].join
      RUBY
      out, err, = Open3.capture3({ "RAILS_ENV" => env }, RbConfig.ruby, "-Ilib", File.join(root, "app.rb"))
      out + err
    end

    def log(env)
      File.read(File.join(root, "log/#{env}.log"))
    end

    it "shows the app's own log in development without any setting, and leaves the log where it was" do
      FileUtils.mkdir_p(File.join(root, "log"))
      expect(app("development")).to match(/ERROR -- : it broke/)
      expect(log("development")).to include("it broke")
      expect(app("development")).not_to include("not said")
    end

    it "leaves alone an app that has a storage" do
      expect(app("development", "Logsafe.storage = #{File.join(root, "mine").inspect}")).to include("has no logs")
      expect(Dir.exist?(File.join(root, "tmp/logsafe"))).to be(false)
    end

    it "does nothing in production, where a storage that was forgotten must be noticed" do
      expect(app("production")).to include("Logsafe.storage is not set")
      expect(Dir.exist?(File.join(root, "tmp/logsafe"))).to be(false)
    end
  end
end

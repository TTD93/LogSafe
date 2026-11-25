# frozen_string_literal: true

require "fileutils"

module Logsafe
  # The storage of a Rails app in development that sets none. No Vector runs on a developer's machine, so
  # the app's log comes here too, beside where it goes otherwise, and the page has something to show.
  # It is what a logger writes to, and the folder the page reads. Lines first go to an open file, which
  # becomes a part when the parts are listed: the page reads each part once, so it has to be finished.
  # ponytail: a line another process is writing at that very moment can miss the page until its copy is
  # gone. A lock around both, if that is ever felt.
  class Development < Storage::Folder
    KEEP = 3 # days, with today
    OPEN_FILES = "open"
    COLOURS = /\e\[[\d;]*m/

    # Streams are called after the program that runs, such as rails or sidekiq. The names an app gives
    # its streams are those of its containers, so here they would hide everything.
    def self.start(root, logger, program: $PROGRAM_NAME)
      logs = new(root, File.basename(program)[/\A#{STREAM}/] || "app")
      logs.prune
      Logsafe.streams = nil
      Logsafe.storage = logs
      logger.broadcast_to(ActiveSupport::Logger.new(logs, level: logger.level, formatter: ::Logger::Formatter.new))
    end

    def initialize(root, stream)
      super(root.to_s)
      @stream = stream
      @last = 0
    end

    # A message, from a logger, which lets one thread in at a time. Each of its lines gets a time of its
    # own, so that they stay in order: what is sorted later is the text.
    def write(message)
      text = message.dup.force_encoding(Encoding::UTF_8).scrub.gsub(COLOURS, "")
      text.lines(chomp: true).reject { |line| line.strip.empty? }.each { |line| add(line) }
    end

    # A logger asks that of what it writes to. Nothing is kept open here.
    def close; end

    def keys(prefix)
      Dir.glob(File.join(@root, OPEN_FILES, "*", "*.log")).each { |file| finish(file) } if prefix == PARTS
      super
    end

    # Deletes what is older than KEEP days.
    def prune
      oldest = (Time.now.utc.to_date - (KEEP - 1)).to_s
      Dir.glob(File.join(@root, "{#{PARTS}*,#{OPEN_FILES}}", "*")).each do |dir|
        day = File.basename(dir)
        FileUtils.rm_rf(dir) if day.match?(DATE) && day < oldest
      end
    end

    private

    def add(line)
      @last = [now, @last + 1].max
      time = Time.at(0, @last, :nsec).utc
      dir = File.join(@root, OPEN_FILES, time.strftime("%F"))
      FileUtils.mkdir_p(dir, mode: 0o700)
      line = "#{time.strftime("%FT%T.%9NZ")} #{line}\n"
      File.open(File.join(dir, "#{@stream}.log"), "a", 0o600) { |file| file.write(line) }
    end

    def finish(file)
      dir = File.join(@root, PARTS, File.basename(file, ".log"), File.basename(File.dirname(file)))
      FileUtils.mkdir_p(dir, mode: 0o700)
      File.rename(file, File.join(dir, "#{now}-#{Process.pid}.log"))
    rescue Errno::ENOENT
      nil # another process was first
    end

    def now
      Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    end

    # A part here is finished, however fresh it is.
    def settled?(_key, stat)
      stat.file?
    end
  end
end

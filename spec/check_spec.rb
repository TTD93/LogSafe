# frozen_string_literal: true

RSpec.describe "Logsafe.check" do
  let(:root) { Dir.mktmpdir("logsafe-spec") }
  let(:now) { Time.now }

  before { Logsafe.storage = root }

  after do
    Logsafe.streams = nil
    FileUtils.rm_rf(root)
  end

  def file(key, minutes_ago)
    path = File.join(root, key)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "")
    File.utime(now - (minutes_ago * 60), now - (minutes_ago * 60), path)
  end

  def part(stream, minutes_ago)
    file("parts/#{stream}/#{now.utc.strftime("%F")}/#{minutes_ago}.log", minutes_ago)
  end

  it "says nothing while lines arrive, however quiet one of the streams is" do
    part "web", 300
    part "worker", 80
    expect { Logsafe.check }.not_to raise_error
  end

  it "takes the newest part of a stream, whichever day it is of" do
    file("parts/web/#{(now.utc.to_date - 1).iso8601}/a.log", 10)
    part "web", 100
    expect { Logsafe.check("web") }.not_to raise_error
    expect { Logsafe.check("web", within: 5 * 60) }.to raise_error(Logsafe::Quiet)
  end

  it "counts a part the shipper may still be writing" do
    part "web", 0
    expect(Logsafe.storage.keys("parts/")).to eq []
    expect { Logsafe.check }.not_to raise_error
  end

  it "fails when nothing arrived for 90 minutes, or for as long as it was told" do
    part "web", 100
    expect { Logsafe.check }.to raise_error(Logsafe::Quiet, /\ANo lines have arrived for 90 minutes\. .*docker logs/)
    expect { Logsafe.check(within: 120 * 60) }.not_to raise_error
    expect { Logsafe.check(within: 60 * 60) }.to raise_error(Logsafe::Quiet, /for 60 minutes/)
  end

  it "fails when there is nothing at all" do
    expect { Logsafe.check }.to raise_error(Logsafe::Quiet)
  end

  it "wants each stream it was given, and names the ones that are quiet" do
    part "web", 100
    part "web", 10
    part "worker", 100
    expect { Logsafe.check("web") }.not_to raise_error
    expect { Logsafe.check("web", "worker", :cron) }.to raise_error(Logsafe::Quiet, /arrived in worker, cron for/)
  end

  # The merge writes day files every hour, whether lines arrive or not, and anyone could make up a name.
  it "is not fooled by a day's file, by another stream, or by what is no part" do
    Logsafe.streams = %w[web]
    part "made-up", 1
    file("2026/11/web.2026-11-20.log.gz", 1)
    file("parts/web/no-date/a.log", 1)
    expect { Logsafe.check }.to raise_error(Logsafe::Quiet)
  end

  it "says so when a storage of your own cannot tell" do
    Logsafe.storage = Object.new
    expect { Logsafe.check }.to raise_error(Logsafe::Error, /has no method times/)
  end

  it "runs as a job on any Active Job backend" do
    Logsafe::CheckJob.logger = Logger.new(nil)
    Logsafe::CheckJob.queue_adapter = :inline
    part "web", 100
    expect { Logsafe::CheckJob.perform_later("web", within: 120 * 60) }.not_to raise_error
    expect { Logsafe::CheckJob.perform_later }.to raise_error(Logsafe::Quiet)
  end
end

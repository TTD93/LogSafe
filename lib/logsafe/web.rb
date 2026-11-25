# frozen_string_literal: true

require "date"
require "erb"
require "uri"

module Logsafe
  # The page to read and search the logs on. A Rack app, to mount where you like:
  #   mount Logsafe::Web, at: "logsafe"
  # It does not ask who is looking: put it behind your own sign-in, see the README.
  class Web
    include ERB::Util

    PAGE = ERB.new(File.read(File.join(__dir__, "web.html.erb")), trim_mode: "-")
    MAX_DAYS = 7 # each day searched is fetched, and kept on this machine for a while
    TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{9}Z\z/
    LOUD = /\b(?:(fatal|error)|warn(?:ing)?)\b/i
    HEADERS = {
      "content-type" => "text/html; charset=utf-8",
      "cache-control" => "no-store",
      "x-frame-options" => "DENY",
      "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
    }.freeze
    # Each response gets a copy of its own: what stands in front of this app, such as Rack::ETag, adds to them.
    TEXT = { "content-type" => "text/plain" }.freeze

    def self.call(env)
      return [405, TEXT.merge("allow" => "GET, HEAD"), ["Only GET"]] unless %w[GET HEAD].include?(env["REQUEST_METHOD"])

      params = begin
        URI.decode_www_form(env["QUERY_STRING"].to_s).to_h.transform_values { |value| value.scrub.delete("\0") }
      rescue ArgumentError
        return [400, TEXT.dup, ["Bad request"]]
      end
      new(params).response
    end

    # Nothing from the address is used before it is checked: these values end up in paths and commands.
    def initialize(params, today: Time.now.utc.to_date)
      @to = date(params["to"]) || today
      @from, @cut = from(date(params["from"]) || today)
      @stream = params["stream"].to_s[/.+/m] # none when it is empty
      @level = params["level"] if Search::LEVELS.key?(params["level"])
      @before = params["before"].to_s[TIME]
      @query = params["q"].to_s.strip
      @streams = []
      @lines = []
      @problems = []
    end

    # What Logsafe itself refuses, such as a missing key, is said on the page. The rest is the app's to handle.
    # The stream asked for is only compared with the ones there are: a name that is none finds nothing.
    def response
      days = Search.sources(@from, @to)
      @streams = days.keys.map(&:first).uniq.sort
      days = days.select { |(stream, _), _| stream == @stream } if @stream
      @lines, @problems = Search.call(days, words: @query.split, level: @level, before: @before)
      [200, HEADERS.dup, [PAGE.result(binding)]]
    rescue Error => e
      @problems = [e.message]
      [500, HEADERS.dup, [PAGE.result(binding)]]
    end

    private

    # The first day to search, and whether that is later than was asked for.
    def from(asked)
      from = asked.clamp(@to - (MAX_DAYS - 1), @to)
      [from, asked < from]
    end

    def date(text)
      Date.strptime(text, "%Y-%m-%d") if text.to_s.match?(DATE)
    rescue Date::Error
      nil
    end

    # The address of this search, with something changed.
    def link(**changes)
      search = { q: @query, stream: @stream, level: @level, from: @from, to: @to, before: @before }
      "?#{URI.encode_www_form(search.merge(changes).compact)}"
    end

    def older
      link(before: @lines.first.last[/\A\S+/]) if @lines.size == Search::LIMIT
    end

    # A line as [class of the row, time, text]. Lines are bytes that some program wrote: not always text.
    def row(line)
      time, text = line.dup.force_encoding("UTF-8").scrub.split(" ", 2)
      found = text.to_s.match(LOUD)
      [found && (found[1] ? "error" : "warn"), time, text.to_s]
    end

    # The text with the words that were searched for marked. Split first and escaped after, piece by piece.
    def marked(text)
      words = @query.split
      return h(text) if words.empty?

      text.split(/(#{Regexp.union(words).source})/i).each_slice(2).map do |plain, word|
        "#{h(plain)}#{"<mark>#{h(word)}</mark>" if word}"
      end.join
    end

    def hue(stream)
      90 + (stream.sum * 137 % 240) # green to purple: red and amber mean something on this page
    end
  end
end

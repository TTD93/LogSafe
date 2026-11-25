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
    QUERY = 500 # characters that can be searched for
    HEADERS = {
      "content-type" => "text/html; charset=utf-8",
      "cache-control" => "no-store",
      "x-frame-options" => "DENY",
      "cross-origin-opener-policy" => "same-origin",
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
      new(params).response(search: here?(env))
    end

    # Whether the page was opened from itself or by hand. A search fetches and decrypts days of logs, and
    # takes a time that depends on what is in them: another website must not be able to start one with
    # the session of someone who is signed in. Browsers that do not say are let through.
    def self.here?(env)
      ["same-origin", "none", nil].include?(env["HTTP_SEC_FETCH_SITE"])
    end

    # Nothing from the address is used before it is checked: these values end up in paths and commands.
    def initialize(params, today: Time.now.utc.to_date)
      @to = date(params["to"]) || today
      @from, @cut = from(date(params["from"]) || today)
      look_for(params["q"].to_s, params["stream"].to_s, params["level"])
      turn(params["before"].to_s[TIME], params["skip"])
      @streams = []
      @lines = []
      @problems = []
    end

    # What Logsafe itself refuses, such as a missing key, is said on the page. The rest is the app's to handle.
    def response(search: true)
      search ? find : @waiting = true
      page(200)
    rescue Error => e
      @problems = [e.message]
      page(500)
    end

    private

    def look_for(words, stream, level)
      @query = words.strip[0, QUERY]
      @words = @query.split.uniq.first(Search::WORDS)
      @stream = stream[/.+/m] # none when it is empty
      @level = level if Search::LEVELS.key?(level)
    end

    # To the lines before a time, and how many of that time itself to skip: see Search.
    def turn(before, skip)
      @before = before
      @skip = skip.to_i.clamp(0, Search::SAME) if before && skip
    end

    def page(status)
      @older = older
      [status, HEADERS.dup, [PAGE.result(binding)]]
    end

    # The stream asked for is only compared with the ones there are: a name that is none finds nothing.
    def find
      days = Search.sources(@from, @to)
      @streams = days.keys.map(&:first).uniq.sort
      days = days.select { |(stream, _), _| stream == @stream } if @stream
      if !@stream && @streams.size > Search::STREAMS
        @problems = ["There are #{@streams.size} streams in these days. Choose one."]
      else
        @lines, @problems = Search.call(days, words: @words, level: @level, before: @before, skip: @skip)
      end
    end

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
      search = { q: @query, stream: @stream, level: @level, from: @from, to: @to }
      "?#{URI.encode_www_form(search.merge(changes).compact)}"
    end

    # A page goes on from the time of its first line, and from how many lines of that time were shown:
    # the rest of them belong on the next page.
    def older
      time = @lines.first.last[/\A\S+/].to_s[TIME] if @lines.size == Search::LIMIT
      return unless time

      shown = @lines.count { |_, line| line.start_with?(time) }
      shown += @skip.to_i if time == @before
      @crowded = time if shown > Search::SAME
      link(before: time, skip: (shown unless @crowded))
    end

    # A line as [class of the row, time, text].
    def row(line)
      time, text = line.split(" ", 2)
      found = text.to_s.match(LOUD)
      [found && (found[1] ? "error" : "warn"), time, text.to_s]
    end

    # The text with the words that were searched for marked. Split first and escaped after, piece by piece.
    def marked(text)
      return h(text) if @words.empty?

      @marks ||= /(#{Regexp.union(@words).source})/i
      text.split(@marks).each_slice(2).map do |plain, word|
        "#{h(plain)}#{"<mark>#{h(word)}</mark>" if word}"
      end.join
    end

    def hue(stream)
      90 + (stream.sum * 137 % 240) # green to purple: red and amber mean something on this page
    end
  end
end

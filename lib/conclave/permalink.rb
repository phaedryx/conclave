# frozen_string_literal: true

require "uri"

module Conclave
  module Permalink
    PATTERN = %r{
      https://[a-z0-9-]+\.slack\.com/archives/
      (?<channel>[CG][A-Z0-9]+)/p(?<digits>\d{16})(?!\d)
      (?:\?(?<query>[^\s>|]*))?
    }x

    def self.extract(text)
      text.to_s.scan(PATTERN).map do |channel, digits, query|
        { channel: channel, ts: "#{digits[0...-6]}.#{digits[-6..]}", thread_ts: thread_ts(query) }
      end
    end

    def self.thread_ts(query)
      return nil if query.nil? || query.empty?

      URI.decode_www_form(query.gsub("&amp;", "&")).to_h["thread_ts"]
    rescue ArgumentError
      nil
    end
    private_class_method :thread_ts
  end
end

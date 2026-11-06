# frozen_string_literal: true

module Conclave
  # Who a message is for. A message addresses agents only when it starts with one or more names and a colon:
  # "coord: hello", "coord, tad_sc-1234: hello", "all: hello". Names are matched whole and case-insensitively
  # against the channel's members; names that aren't members are ignored. Anything else, including Slack
  # @-mentions, addresses nobody.
  module Addressing
    NAME = /[\w-]+/
    PREFIX = /\A\s*(?<names>#{NAME}(?:\s*,\s*#{NAME})*)\s*:/
    ALL = "all"

    def self.parse(text, members:)
      match = PREFIX.match(text.to_s)
      return { agents: [], all: false } unless match

      names = match[:names].split(",").map { |name| name.strip.downcase }
      agents = names.filter_map { |name| members.find { |member| member.casecmp?(name) } }.uniq
      { agents: agents, all: names.include?(ALL) }
    end
  end
end

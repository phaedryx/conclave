# frozen_string_literal: true

module Conclave
  module Addressing
    ALL_PATTERN = /(?<![\w@.])@all(?![\w-])|<!here(?:\|[^>]*)?>|<!channel(?:\|[^>]*)?>/i

    def self.parse(text, members:)
      text = text.to_s
      { agents: named_agents(text, members), all: text.match?(ALL_PATTERN) }
    end

    def self.named_agents(text, members)
      found = members.filter_map do |member|
        match = text.match(/(?<![\w@.])@#{Regexp.escape(member)}(?![\w-])/i)
        [match.begin(0), member] if match
      end
      found.sort_by(&:first).map(&:last).uniq
    end
    private_class_method :named_agents
  end
end

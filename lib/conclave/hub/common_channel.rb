# frozen_string_literal: true

module Conclave
  class Hub
    # The channel every agent joins on its first registration. Configured by name or ID; a name is looked up once.
    # An agent that has joined is remembered, so a later registration does not rejoin: /conclave remove sticks.
    class CommonChannel
      NotFound = Class.new(StandardError)
      ID_PATTERN = /\A[CG][A-Z0-9]+\z/

      def initialize(store:, slack:, notices:, channel:)
        @store = store
        @slack = slack
        @notices = notices
        @channel = channel.to_s.strip
      end

      # Returns the channel_id, or nil when the agent has joined before or the join failed (reported; the agent
      # is not marked, so the next registration tries again).
      def ensure_joined(agent)
        return if @store.common_joined?(agent)

        id = channel_id
        ChannelJoin.ensure(@slack, id)
        @store.add_membership(agent, id)
        @store.mark_common_joined(agent)
        @notices.joined_common(agent, id)
        id
      rescue NotFound, ChannelJoin::Private, Slack::Client::Error => e
        Agents.report("common channel join failed for #{agent}: #{e.message}")
        nil
      end

      private

      # Memoized only on success, so a lookup that failed is retried on the next registration.
      def channel_id
        @channel_id ||= ID_PATTERN.match?(@channel) ? @channel : lookup(@channel.delete_prefix("#").downcase)
      end

      def lookup(name)
        cursor = nil
        loop do
          page = @slack.list_channels(cursor: cursor)
          found = page.fetch("channels", []).find { |channel| channel["name"] == name }
          return found["id"] if found

          cursor = page.dig("response_metadata", "next_cursor").to_s
          raise NotFound, "default_channel ##{name} not found" if cursor.empty?
        end
      end
    end
  end
end

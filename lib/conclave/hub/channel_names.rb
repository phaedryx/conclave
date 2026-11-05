# frozen_string_literal: true

module Conclave
  module Hub
    # Channel name from Slack, cached per channel_id. Falls back to the id (uncached) if Slack errors.
    class ChannelNames
      def initialize(slack)
        @slack = slack
        @names = {}
      end

      def [](channel_id)
        @names.fetch(channel_id) do
          name = @slack.channel_info(channel: channel_id).dig("channel", "name")
          @names[channel_id] = name if name
          name || channel_id
        end
      rescue Slack::Client::Error => e
        Agents.report("channel lookup failed for #{channel_id}: #{e.message}")
        channel_id
      end
    end
  end
end

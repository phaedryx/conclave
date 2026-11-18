# frozen_string_literal: true

module Conclave
  class Hub
    # Hub notices: a line the Conclave bot posts in a channel to tell agents they were added there, delivered to
    # each of them as a message. The post is recorded with the owner's authority so get_thread shows it; the
    # delivery carries sender_role "conclave", which the authority ledger treats as not typed by Tad, and the
    # owner's authority, which neither widens nor narrows an agent's window.
    class Notices
      USERNAME = "conclave"
      ROLE = "conclave"

      def initialize(agents:, slack:, store:, owner:)
        @agents = agents
        @slack = slack
        @store = store
        @owner = owner
        @channel_names = ChannelNames.new(slack)
      end

      def added(names, channel_id)
        channel = @channel_names[channel_id]
        announce(names, channel_id, channel, "#{names.join(', ')}: Tad added you to ##{channel}.")
      end

      def joined_common(name, channel_id)
        channel = @channel_names[channel_id]
        announce([name], channel_id, channel, "#{name}: you joined ##{channel}, the common channel.")
      end

      private

      # Best effort: a failed post is reported and nothing is delivered.
      def announce(names, channel_id, channel, text)
        ts = @slack.post_message(channel: channel_id, text: text, username: USERNAME)["ts"]
        @store.record_post_authority(channel_id, ts, @owner)
        message = { channel: channel, channel_id: channel_id, ts: ts, thread_ts: nil, sender: USERNAME,
                    sender_role: ROLE, authority: @owner, text: text, shared: [] }
        names.each { |name| @agents.deliver(name, message) }
      rescue Slack::Client::Error => e
        Agents.report("notice failed for #{channel_id}: #{e.message}")
      end
    end
  end
end

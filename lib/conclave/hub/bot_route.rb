# frozen_string_literal: true

module Conclave
  class Hub
    # Routes another Slack app's bot messages. A bot is never a person, consulted or not: its messages never reach the
    # human path, carry no authority, and never reset the loop guard. A consulted bot reaches an agent it addresses,
    # or one that has posted in the thread it replies in.
    class BotRoute
      SUBTYPES = [nil, "thread_broadcast", "bot_message"].freeze

      def initialize(agents:, store:, channel_names:, bot_id:)
        @agents = agents
        @store = store
        @channel_names = channel_names
        @bot_id = bot_id
      end

      # Any bot but ours.
      def handles?(event)
        !event["bot_id"].nil? && event["bot_id"] != @bot_id && SUBTYPES.include?(event["subtype"])
      end

      def handle(event)
        @store.set_last_seen(event["channel"], event["ts"])
        targets(event).each { |agent| @agents.deliver_from_bot(agent, message(event)) }
      end

      private

      def targets(event)
        channel = event["channel"]
        members = @store.members(channel).select { |agent| @store.consults?(agent, event["bot_id"]) }
        addr = Addressing.parse(event["text"], members: members)
        addressed = addr[:all] ? members : addr[:agents]
        members.select do |agent|
          addressed.include?(agent) || (event["thread_ts"] && @store.agent_thread?(agent, channel, event["thread_ts"]))
        end
      end

      def message(event)
        { channel: @channel_names[event["channel"]], channel_id: event["channel"], ts: event["ts"],
          thread_ts: event["thread_ts"], sender: event["user"] || event["bot_id"], sender_role: "bot",
          authority: Authority::NONE, text: event["text"].to_s, shared: [] }
      end
    end
  end
end

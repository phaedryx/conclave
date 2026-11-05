# frozen_string_literal: true

module Conclave
  class Hub
    # Decides which messages of a Slack thread an agent may read. Text from anyone who may not direct
    # the agent is replaced by a placeholder and never reaches it.
    class ThreadFilter
      def initialize(authority:, bot_id:, store:)
        @authority = authority
        @store = store
        @bot_id = bot_id
      end

      def call(message, agent, channel_id)
        user = message["user"]
        if user == @authority.owner
          visible(message, user, "owner")
        elsif @bot_id && message["bot_id"] == @bot_id
          agent_post(message, agent, channel_id)
        elsif (role = @authority.human_role(user, agent))
          visible(message, user, role.to_s)
        else
          hidden(message["ts"])
        end
      end

      private

      # Our bot's posts carry the authority recorded when they were sent; an unknown one is hidden.
      def agent_post(message, agent, channel_id)
        authority = @store.post_authority(channel_id, message["ts"])
        return hidden(message["ts"]) unless @authority.permits?(authority, agent)

        visible(message, message["username"], "agent")
      end

      def visible(message, sender, role)
        { ts: message["ts"], sender: sender, sender_role: role, text: message["text"] }
      end

      def hidden(ts)
        { ts: ts, sender: nil, sender_role: nil, text: "[hidden message ts=#{ts}]" }
      end
    end
  end
end

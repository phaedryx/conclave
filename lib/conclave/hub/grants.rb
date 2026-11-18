# frozen_string_literal: true

module Conclave
  class Hub
    # Per-agent grants. People are authorized (they may direct the agent); other apps' bots are only consulted (see
    # BotRoute). Granting looks the user up first, so a bot is never authorized as a person; a failed lookup refuses.
    class Grants
      def initialize(store:, slack:)
        @store = store
        @slack = slack
      end

      # nil when applied, else why not. verb is authorize, deauthorize, consult or unconsult.
      def apply(verb, agent, user)
        case verb
        when "authorize" then authorize(agent, user)
        when "consult" then consult(agent, user)
        when "deauthorize" then @store.deauthorize(agent, user) && nil
        else @store.unconsult(agent, user) && nil
        end
      end

      private

      def authorize(agent, user)
        info = user_info(user)
        return info if info.is_a?(String)
        return "<@#{user}> is a bot. Use consult for bots." if info["is_bot"]

        @store.authorize(agent, user)
        nil
      end

      def consult(agent, user)
        info = user_info(user)
        return info if info.is_a?(String)
        return "<@#{user}> isn't a bot. Use authorize for people." unless info["is_bot"]

        bot_id = info.dig("profile", "bot_id")
        return "Couldn't find <@#{user}>'s bot id." if bot_id.to_s.empty?

        @store.consult(agent, user, bot_id)
        nil
      end

      # The users.info user, or a refusal.
      def user_info(user)
        @slack.user_info(user: user)["user"] || "Couldn't look up <@#{user}>: no user"
      rescue Slack::Client::Error => e
        "Couldn't look up <@#{user}>: #{e.code || e.message}"
      end
    end
  end
end

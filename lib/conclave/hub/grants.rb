# frozen_string_literal: true

module Conclave
  class Hub
    # Per-agent grants. People are authorized (they may direct the agent); other apps' bots are only consulted (see
    # BotRoute). Granting looks the user up first, so a bot is never authorized as a person; a failed lookup refuses.
    class Grants
      def initialize(store:, slack:, notices:)
        @store = store
        @slack = slack
        @notices = notices
      end

      # nil when applied, else why not. verb is authorize, deauthorize, consult or unconsult. A consult change is
      # announced to the agent in channel_id.
      def apply(verb, agent, user, channel_id)
        case verb
        when "authorize" then authorize(agent, user)
        when "consult" then consult(agent, user, channel_id)
        when "deauthorize" then @store.deauthorize(agent, user) && nil
        else unconsult(agent, user, channel_id)
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

      def consult(agent, user, channel_id)
        info = user_info(user)
        return info if info.is_a?(String)
        return "<@#{user}> isn't a bot. Use authorize for people." unless info["is_bot"]

        bot_id = info.dig("profile", "bot_id")
        return "Couldn't find <@#{user}>'s bot id." if bot_id.to_s.empty?

        @store.consult(agent, user, bot_id)
        @notices.consulted(agent, display_name(info), user, channel_id)
        nil
      end

      # The notice names the bot when Slack can; the grant goes regardless.
      def unconsult(agent, user, channel_id)
        return unless @store.unconsult(agent, user)

        info = user_info(user)
        @notices.unconsulted(agent, info.is_a?(String) ? nil : display_name(info), user, channel_id)
        nil
      end

      def display_name(info)
        [info.dig("profile", "display_name"), info["real_name"], info["name"]].find { |name| !name.to_s.empty? }
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

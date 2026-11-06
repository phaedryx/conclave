# frozen_string_literal: true

module Conclave
  class Hub
    # Owner-only management commands: in-channel "agent: authorize <@U…>" and the /conclave slash command.
    class Commands
      ONLY_OWNER = "Only Tad can do that."
      USAGE = "Usage: /conclave invite <agent> | remove <agent> | authorize <agent> @person | " \
              "deauthorize <agent> @person"
      PRIVATE_CHANNEL = "Add the Conclave app to this private channel first."
      PRIVATE_CHANNEL_CODE = "method_not_supported_for_channel_type"
      USER_REF = /<@(?<user>[UW][A-Z0-9]+)(?:\|[^>]*)?>/
      TEXT_COMMAND = /\A\s*(?<agent>[\w-]+)\s*:\s*(?<verb>authorize|deauthorize)\s+#{USER_REF}\s*\z/i
      SLASH_USER_COMMAND = /\A(?<verb>authorize|deauthorize)\s+(?<agent>\S+)\s+#{USER_REF}\s*\z/i
      SLASH_AGENT_COMMAND = /\A(?<verb>invite|remove)\s+(?<agent>\S+)\s*\z/i

      def initialize(store:, authority:, slack:, owner:)
        @store = store
        @authority = authority
        @slack = slack
        @owner = owner
      end

      # True when the whole message is an owner's in-channel authorize/deauthorize command, so it is consumed.
      # One command per message; a message that merely contains one is delivered normally.
      def handle_text(event) # rubocop:disable Naming/PredicateMethod
        return false unless event["user"] == @owner

        match = TEXT_COMMAND.match(event["text"].to_s)
        run_text_command(event, match) if match
        !match.nil?
      end

      def handle_slash(payload)
        return ONLY_OWNER unless payload["user_id"] == @owner

        text = payload["text"].to_s.strip
        if (match = SLASH_AGENT_COMMAND.match(text))
          agent_command(match[:verb].downcase, match[:agent].downcase, payload["channel_id"])
        elsif (match = SLASH_USER_COMMAND.match(text))
          user_command(match)
        else
          USAGE
        end
      end

      private

      def run_text_command(event, match)
        agent = @store.members(event["channel"]).find { |member| member.casecmp?(match[:agent]) }
        return react(event, "x") unless agent

        apply_grant(match[:verb], agent, match[:user])
        react(event, "white_check_mark")
      end

      def user_command(match)
        agent = match[:agent].downcase
        apply_grant(match[:verb], agent, match[:user])
        "#{match[:verb].capitalize}d <@#{match[:user]}> for #{agent}."
      end

      def apply_grant(verb, agent, user)
        verb.casecmp?("authorize") ? @store.authorize(agent, user) : @store.deauthorize(agent, user)
      end

      def agent_command(verb, agent, channel_id)
        return invite(agent, channel_id) if verb == "invite"

        @store.remove_membership(agent, channel_id)
        "#{agent} removed from this channel."
      end

      # A private channel can't be joined: the bot is either in it already (Tad added the app) or Tad must add it.
      def invite(agent, channel_id)
        channel = @slack.channel_info(channel: channel_id)["channel"] || {}
        if channel["is_private"]
          return PRIVATE_CHANNEL unless channel["is_member"]
        else
          @slack.join(channel: channel_id)
        end
        @store.add_membership(agent, channel_id)
        "#{agent} invited to this channel."
      rescue Slack::Client::Error => e
        e.code == PRIVATE_CHANNEL_CODE ? PRIVATE_CHANNEL : "Couldn't join this channel: #{e.message}"
      end

      def react(event, name)
        @slack.add_reaction(channel: event["channel"], ts: event["ts"], name: name)
      rescue Slack::Client::Error => e
        Agents.report("#{name} reaction failed for #{event['channel']}/#{event['ts']}: #{e.message}")
      end
    end
  end
end

# frozen_string_literal: true

module Conclave
  module Hub
    # Owner-only management commands: in-channel "@agent authorize <@U…>" and the /conclave slash command.
    class Commands
      ONLY_OWNER = "Only Tad can do that."
      USAGE = "Usage: /conclave invite <agent> | remove <agent> | authorize <agent> @person | " \
              "deauthorize <agent> @person"
      PRIVATE_CHANNEL = "Add the Conclave app to this private channel first."
      PRIVATE_CHANNEL_CODE = "method_not_supported_for_channel_type"
      USER_REF = /<@(?<user>[UW][A-Z0-9]+)(?:\|[^>]*)?>/
      TEXT_COMMAND = /(?<![\w@.])@(?<agent>[\w-]+)\s+(?<verb>authorize|deauthorize)\s+#{USER_REF}/i
      SLASH_USER_COMMAND = /\A(?<verb>authorize|deauthorize)\s+(?<agent>\S+)\s+#{USER_REF}\s*\z/i
      SLASH_AGENT_COMMAND = /\A(?<verb>invite|remove)\s+(?<agent>\S+)\s*\z/i

      def initialize(store:, authority:, slack:, owner:)
        @store = store
        @authority = authority
        @slack = slack
        @owner = owner
      end

      # True when the message held an owner's in-channel authorize/deauthorize command, so it is consumed
      # even if it also addresses other agents.
      def handle_text(event) # rubocop:disable Naming/PredicateMethod
        return false unless event["user"] == @owner

        matches = event["text"].to_s.to_enum(:scan, TEXT_COMMAND).map { Regexp.last_match }
        matches.each { |match| run_text_command(event, match) }
        !matches.empty?
      end

      def handle_slash(payload)
        return ONLY_OWNER unless payload["user_id"] == @owner

        text = payload["text"].to_s.strip
        if (match = SLASH_AGENT_COMMAND.match(text))
          agent_command(match[:verb].downcase, match[:agent], payload["channel_id"])
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
        apply_grant(match[:verb], match[:agent], match[:user])
        "#{match[:verb].capitalize}d <@#{match[:user]}> for #{match[:agent]}."
      end

      def apply_grant(verb, agent, user)
        verb.casecmp?("authorize") ? @store.authorize(agent, user) : @store.deauthorize(agent, user)
      end

      def agent_command(verb, agent, channel_id)
        return invite(agent, channel_id) if verb == "invite"

        @store.remove_membership(agent, channel_id)
        "#{agent} removed from this channel."
      end

      def invite(agent, channel_id)
        @slack.join(channel: channel_id)
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

# frozen_string_literal: true

module Conclave
  class Hub
    # Owner-only management commands: in-channel "agent: authorize <@U…>" and the /conclave slash command.
    class Commands
      ONLY_OWNER = "Only Tad can do that."
      USAGE = "Usage: /conclave invite <agent> | remove <agent> | channel <name> <agent> [<agent>…] | " \
              "authorize <agent> @person | deauthorize <agent> @person | consult <agent> @bot | unconsult <agent> @bot"
      PRIVATE_CHANNEL = "Add the Conclave app to this private channel first."
      BAD_CHANNEL_NAME = "Channel names are lowercase letters, numbers, hyphens and underscores, up to 80 characters."
      USER_REF = /<@(?<user>[UW][A-Z0-9]+)(?:\|[^>]*)?>/
      GRANT_VERB = /authorize|deauthorize|consult|unconsult/
      TEXT_COMMAND = /\A\s*(?<agent>[\w-]+)\s*:\s*(?<verb>#{GRANT_VERB})\s+#{USER_REF}\s*\z/i
      SLASH_USER_COMMAND = /\A(?<verb>#{GRANT_VERB})\s+(?<agent>\S+)\s+#{USER_REF}\s*\z/i
      SLASH_AGENT_COMMAND = /\A(?<verb>invite|remove)\s+(?<agent>\S+)\s*\z/i
      SLASH_CHANNEL_COMMAND = /\Achannel\s+(?<name>\S+)\s+(?<agents>\S+(?:\s+\S+)*)\s*\z/i
      CHANNEL_NAME = /\A[a-z0-9_-]{1,80}\z/

      def initialize(store:, authority:, slack:, owner:, notices:)
        @store = store
        @authority = authority
        @slack = slack
        @owner = owner
        @notices = notices
        @grants = Grants.new(store: store, slack: slack, notices: notices)
      end

      # True when the whole message is an owner's in-channel grant command (authorize, consult, or their undo), so it is
      # consumed.
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
          user_command(match, payload)
        elsif (match = SLASH_CHANNEL_COMMAND.match(text))
          channel_command(match)
        else
          USAGE
        end
      end

      private

      def run_text_command(event, match)
        agent = @store.members(event["channel"]).find { |member| member.casecmp?(match[:agent]) }
        return react(event, "x") unless agent

        refusal = @grants.apply(match[:verb].downcase, agent, match[:user], event["channel"])
        react(event, refusal ? "x" : "white_check_mark")
      end

      def user_command(match, payload)
        agent = match[:agent].downcase
        verb = match[:verb].downcase
        refusal = @grants.apply(verb, agent, match[:user], payload["channel_id"])
        refusal || "#{verb.capitalize}#{verb.end_with?('e') ? 'd' : 'ed'} <@#{match[:user]}> for #{agent}."
      end

      def agent_command(verb, agent, channel_id)
        return invite(agent, channel_id) if verb == "invite"

        @store.remove_membership(agent, channel_id)
        "#{agent} removed from this channel."
      end

      def invite(agent, channel_id)
        return "#{agent} is already in this channel." if @store.members(channel_id).include?(agent)

        ChannelJoin.ensure(@slack, channel_id)
        @store.add_membership(agent, channel_id)
        @notices.added([agent], channel_id)
        "#{agent} invited to this channel."
      rescue ChannelJoin::Private
        PRIVATE_CHANNEL
      rescue Slack::Client::Error => e
        "Couldn't join this channel: #{e.message}"
      end

      # Agents must have registered at least once; the name follows Slack's rules. Nothing is created otherwise.
      def channel_command(match)
        agents = match[:agents].split.map(&:downcase).uniq
        unknown = agents - @store.known_agents
        return unknown_agents(unknown) unless unknown.empty?

        name = match[:name].delete_prefix("#").downcase
        return BAD_CHANNEL_NAME unless CHANNEL_NAME.match?(name)

        create_channel(name, agents)
      rescue Slack::Client::Error => e
        return "##{name} already exists. Run /conclave invite from inside it." if e.code == "name_taken"

        "Couldn't create ##{name}: #{e.message}"
      end

      def unknown_agents(names)
        "Unknown #{names.size == 1 ? 'agent' : 'agents'}: #{names.join(', ')}."
      end

      def create_channel(name, agents)
        channel_id = @slack.create_channel(name: name).dig("channel", "id")
        invite_note = invite_owner(channel_id)
        agents.each { |agent| @store.add_membership(agent, channel_id) }
        @notices.added(agents, channel_id)
        "Created ##{name} with #{agents.join(', ')}.#{invite_note}"
      end

      # Empty when Tad is in the channel; otherwise the reason, appended to the reply.
      def invite_owner(channel_id)
        @slack.invite(channel: channel_id, users: @owner)
        ""
      rescue Slack::Client::Error => e
        " Couldn't invite you: #{e.message}"
      end

      def react(event, name)
        @slack.add_reaction(channel: event["channel"], ts: event["ts"], name: name)
      rescue Slack::Client::Error => e
        Agents.report("#{name} reaction failed for #{event['channel']}/#{event['ts']}: #{e.message}")
      end
    end
  end
end

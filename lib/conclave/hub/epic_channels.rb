# frozen_string_literal: true

module Conclave
  class Hub
    # Finds or creates the public channel for a story's epic and joins the agent to it.
    class EpicChannels
      MAX_NAME = 80

      def initialize(store:, slack:, shortcut:, owner:)
        @store = store
        @slack = slack
        @shortcut = shortcut
        @owner = owner
      end

      # Returns the channel_id, or nil when there is nothing to join (or Shortcut is unavailable).
      def ensure_joined(agent)
        return if @store.epic_joined?(agent)

        story_id = AgentName.story_id(agent)
        return unless story_id

        epic = @shortcut.epic_for_story(story_id)
        return unless epic

        channel_id = @store.epic_channel(epic[:id]) || create_channel(epic)
        @store.add_membership(agent, channel_id)
        @store.mark_epic_joined(agent)
        channel_id
      rescue Shortcut::Client::Error => e
        Agents.report("epic lookup failed for #{agent}: #{e.message}")
        nil
      end

      private

      def create_channel(epic)
        slug = slug_for(epic)
        channel_id = create(slug) || create(disambiguated(slug, epic[:id])) || raise_taken(slug)
        @store.set_epic_channel(epic[:id], channel_id)
        invite_owner(channel_id)
        channel_id
      end

      # nil on name_taken so the caller can retry; any other Slack error propagates.
      def create(name)
        @slack.create_channel(name: name).dig("channel", "id")
      rescue Slack::Client::Error => e
        raise unless e.code == "name_taken"

        nil
      end

      def raise_taken(name) = raise(Slack::Client::Error.new("channel name taken: #{name}", code: "name_taken"))

      def slug_for(epic)
        "epic-#{epic[:id]}-#{epic[:name].downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"[0, MAX_NAME]
      end

      def disambiguated(slug, epic_id)
        suffix = "-#{epic_id}"
        "#{slug[0, MAX_NAME - suffix.length]}#{suffix}"
      end

      def invite_owner(channel_id)
        @slack.invite(channel: channel_id, users: @owner)
      rescue Slack::Client::Error => e
        Agents.report("inviting owner to #{channel_id} failed: #{e.message}")
      end
    end
  end
end

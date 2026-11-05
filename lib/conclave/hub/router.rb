# frozen_string_literal: true

module Conclave
  module Hub
    # Routes Slack message events to agents. A message reaches an agent only when it addresses that agent
    # and the sender is the owner or authorized for it. Everything else is dropped silently.
    class Router
      TS_FORMAT = /\A\d{10}\.\d{6}\z/
      NOTE_USERNAME = "conclave"
      FetchError = Class.new(StandardError)

      def initialize(agents:, authority:, store:, slack:, bot_id:, commands:) # rubocop:disable Metrics/ParameterLists
        @agents = agents
        @authority = authority
        @store = store
        @slack = slack
        @bot_id = bot_id
        @commands = commands
        @owner = authority.owner
        @channel_names = ChannelNames.new(slack)
      end

      def handle_message(event)
        return if ignored?(event)

        channel = event["channel"]
        @store.set_last_seen(channel, event["ts"])
        @agents.human_posted(channel_id: channel, thread_key: event["thread_ts"] || event["ts"],
                             user_id: event["user"])
        return if @commands.handle_text(event)

        permitted = permitted_targets(event)
        deliver_all(event, permitted) unless permitted.empty?
      end

      private

      def ignored?(event)
        event["subtype"] || event["user"].nil? || (!@bot_id.nil? && event["bot_id"] == @bot_id)
      end

      # [[agent, role], ...] for the addressed agents the sender may direct.
      def permitted_targets(event)
        members = @store.members(event["channel"])
        addr = Addressing.parse(event["text"], members: members)
        (addr[:all] ? members : addr[:agents]).filter_map do |agent|
          role = @authority.human_role(event["user"], agent)
          [agent, role] if role
        end
      end

      def deliver_all(event, permitted)
        shared = event["user"] == @owner ? shared_messages(event) : []
        channel_name = @channel_names[event["channel"]]
        permitted.each do |agent, role|
          @agents.deliver(agent, message(event, channel_name, role, shared))
        end
      end

      def message(event, channel_name, role, shared)
        { channel: channel_name, channel_id: event["channel"], ts: event["ts"], thread_ts: event["thread_ts"],
          sender: event["user"], sender_role: role.to_s, authority: event["user"], text: event["text"].to_s,
          shared: shared }
      end

      def shared_messages(event)
        text = event["text"].to_s
        urls = text.to_enum(:scan, Permalink::PATTERN).map { Regexp.last_match(0) }
        Permalink.extract(text).zip(urls).filter_map do |link, url|
          fetch(link)
        rescue Slack::Client::Error, FetchError => e
          reply_error(event, "Couldn't read linked message #{url}: #{e.message}")
          nil
        end
      end

      def fetch(link)
        raise FetchError, "invalid timestamp" unless valid_timestamps?(link)

        found = fetch_messages(link).find { |message| message["ts"] == link[:ts] }
        raise FetchError, "message not found" unless found

        { author: found["user"] || found["username"] || found["bot_id"], text: found["text"].to_s, ts: link[:ts] }
      end

      def valid_timestamps?(link)
        [link[:ts], link[:thread_ts] || link[:ts]].all? { |value| TS_FORMAT.match?(value) }
      end

      def fetch_messages(link)
        if link[:thread_ts]
          @slack.replies(channel: link[:channel], ts: link[:thread_ts])["messages"]
        else
          @slack.history(channel: link[:channel], latest: link[:ts], inclusive: true, limit: 1)["messages"]
        end.to_a
      end

      def reply_error(event, text)
        @slack.post_message(channel: event["channel"], thread_ts: event["thread_ts"] || event["ts"],
                            username: NOTE_USERNAME, text: text)
      rescue Slack::Client::Error => e
        Agents.report("link error reply failed for #{event['channel']}/#{event['ts']}: #{e.message}")
      end
    end
  end
end

# frozen_string_literal: true

module Conclave
  class Hub
    # Registry of online agent connections plus outbound posting. Each agent's authority window is persisted in
    # the store. Not thread-safe: the hub serializes calls.
    class Agents # rubocop:disable Metrics/ClassLength
      EMOJI = %i[robot_face ghost alien space_invader jack_o_lantern owl fox_face panda_face tiger
                 penguin frog octopus crab dolphin unicorn_face bee].map { |name| ":#{name}:" }.freeze
      DELIVERED_LIMIT = 200
      NOTE_USERNAME = "conclave"

      # Counts agent-to-agent deliveries per key and remembers which keys already got the pause note. A key is a
      # thread ts, or a Post#channel_key for top-level posts.
      class LoopGuard
        def initialize(limit)
          @limit = limit
          @counts = Hash.new(0)
          @noted = {}
        end

        def blocked?(thread_key)
          @counts[thread_key] >= @limit
        end

        def record(thread_key)
          @counts[thread_key] += 1
        end

        # True exactly once per key until reset.
        def first_block?(thread_key)
          return false if @noted[thread_key]

          @noted[thread_key] = true
        end

        def reset(thread_key)
          @counts.delete(thread_key)
          @noted.delete(thread_key)
        end
      end

      # Per agent: the authority window, persisted, and the authority of the last DELIVERED_LIMIT deliveries by ts.
      #
      # The window is the narrowest authority delivered since the agent's last post; a post resets it to that post's
      # authority. The first delivery after a post replaces the window, later ones narrow it. Whether a delivery has
      # come since the last post is kept in memory only, so after a restart the first delivery narrows the stored
      # window instead of replacing it: fail closed for one post. An agent with no stored window starts as the owner.
      class AuthorityLedger
        def initialize(authority, store)
          @authority = authority
          @store = store
          @closed = {}
          @by_ts = Hash.new { |hash, agent| hash[agent] = {} }
        end

        def record(agent, ts, delivered)
          delivered = Authority::NONE unless delivered.is_a?(String)
          @by_ts[agent][ts] = delivered
          @by_ts[agent].shift while @by_ts[agent].size > DELIVERED_LIMIT
          window = @closed[agent] ? delivered : @authority.combine(current(agent), delivered)
          @closed[agent] = false
          @store.set_agent_authority(agent, window)
        end

        def current(agent) = @store.agent_authority(agent) || @authority.owner

        # Closes the window: the agent's next delivery starts a new one.
        def posted(agent, authority)
          @closed[agent] = true
          @store.set_agent_authority(agent, authority)
        end

        # nil without a reply target. A target missing from the ledger (unknown, another agent's, evicted)
        # fails closed to NONE.
        def replied(agent, ts) = (@by_ts[agent].fetch(ts, Authority::NONE) if ts)
      end

      def self.report(text)
        if Conclave.respond_to?(:logger) && Conclave.logger
          Conclave.logger.warn(text)
        else
          warn("conclave: #{text}")
        end
      end

      # Queue payloads come back from JSON with string keys, and :none as "none".
      module Payload
        def self.restore(payload)
          message = payload.to_h { |key, value| [key.to_sym, value] }
          message[:authority] = Authority::NONE if message[:authority] == "none"
          message[:shared] = (message[:shared] || []).map { |entry| entry.to_h { |key, value| [key.to_sym, value] } }
          message
        end
      end

      Post = Struct.new(:agent, :channel_id, :text, :thread_ts, :ts, :authority) do
        def self.channel_key(channel_id) = [:channel, channel_id]

        # Top-level posts all count against their channel, so a fresh ts per post can't dodge the guard.
        def guard_key = thread_ts || Post.channel_key(channel_id)
      end

      def initialize(store:, authority:, slack:, loop_guard_limit:, queue_limit:)
        @store = store
        @authority = authority
        @slack = slack
        @loop_guard_limit = loop_guard_limit
        @queue_limit = queue_limit
        @connections = {}
        @ledger = AuthorityLedger.new(authority, store)
        @guard = LoopGuard.new(loop_guard_limit)
        @channel_names = ChannelNames.new(slack)
      end

      # A closed connection still registered under the name (a fast reconnect) counts as free.
      def register(name, connection)
        existing = @connections[name]
        return :name_taken if existing && !existing.closed?

        unregister(name, existing) if existing
        @connections[name] = connection
        replay(name, connection)
        :ok
      rescue StandardError
        unregister(name, connection) # all or nothing: a failed drain must not leave the name taken
        raise
      end

      # With a connection, deletes only if it is still the one registered under the name.
      def unregister(name, connection = nil)
        return @connections.delete(name) if connection.nil?

        @connections.delete(name) if @connections[name].equal?(connection)
      end

      def online?(name) = @connections.key?(name)

      def deliver(agent, message)
        connection = @connections[agent]
        return if connection && !connection.closed? && deliver_online(agent, connection, message)

        unregister(agent, connection) if connection
        record_authority(agent, message)
        @store.enqueue(agent, message, limit: @queue_limit)
        react_offline(message)
      end

      def post(agent:, channel_id:, text:, thread_ts: nil, in_reply_to_ts: nil)
        response = @slack.post_message(channel: channel_id, text: text, thread_ts: thread_ts,
                                       username: agent, icon_emoji: EMOJI[agent.sum % EMOJI.size])
        ts = response["ts"]
        authority = @authority.combine(@ledger.current(agent), @ledger.replied(agent, in_reply_to_ts))
        @ledger.posted(agent, authority)
        @store.record_post_authority(channel_id, ts, authority)
        route_to_peers(Post.new(agent, channel_id, text, thread_ts, ts, authority))
        { ts: ts }
      end

      # A post from the owner or an authorized person resets its thread and the channel's top-level count.
      def human_posted(channel_id:, thread_key:, user_id:)
        return unless owner_or_authorized?(channel_id, user_id)

        @guard.reset(thread_key)
        @guard.reset(Post.channel_key(channel_id))
      end

      private

      # Delivers the offline queue in order. If the connection goes away mid-replay, the undelivered payloads go back
      # on the queue in order (they still carry their zzz reaction) and the connection is unregistered.
      def replay(name, connection)
        payloads = @store.drain(name)
        failed = payloads.index { |payload| !deliver_online(name, connection, Payload.restore(payload)) }
        return unless failed

        unregister(name, connection)
        payloads.drop(failed).each { |payload| @store.enqueue(name, payload, limit: @queue_limit) }
      end

      def deliver_online(agent, connection, message)
        record_authority(agent, message)
        connection.deliver(message)
      end

      def record_authority(agent, message) = @ledger.record(agent, message[:ts], message[:authority])

      def route_to_peers(post)
        addressees(post.agent, post.channel_id, post.text).each do |peer|
          next unless @authority.permits?(post.authority, peer)
          next if blocked_by_guard?(post)

          @guard.record(post.guard_key)
          @guard.record(post.ts) unless post.thread_ts # the reply thread a top-level post starts
          deliver(peer, peer_message(post))
        end
      end

      def addressees(agent, channel_id, text)
        peers = @store.members(channel_id) - [agent]
        Addressing.parse(text, members: peers) => { agents:, all: }
        all ? peers : agents
      end

      def peer_message(post)
        { channel: @channel_names[post.channel_id], channel_id: post.channel_id, ts: post.ts,
          thread_ts: post.thread_ts, sender: post.agent, sender_role: "agent", authority: post.authority,
          text: post.text, shared: [] }
      end

      def blocked_by_guard?(post)
        return false unless @guard.blocked?(post.guard_key)

        post_pause_note(post) if @guard.first_block?(post.guard_key)
        true
      end

      def post_pause_note(post)
        response = @slack.post_message(channel: post.channel_id, thread_ts: post.thread_ts, username: NOTE_USERNAME,
                                       text: pause_note(post))
        @store.record_post_authority(post.channel_id, response["ts"], @authority.owner) if response["ts"]
      rescue Slack::Client::Error => e
        Agents.report("pause note failed for #{post.channel_id}/#{post.thread_ts || 'top level'}: #{e.message}")
      end

      def pause_note(post)
        if post.thread_ts
          "Pausing agent-to-agent messages in this thread after #{@loop_guard_limit} exchanges. " \
            "@tad, reply here to continue."
        else
          "Pausing top-level agent-to-agent messages in this channel after #{@loop_guard_limit} exchanges. " \
            "@tad, post here to continue."
        end
      end

      def owner_or_authorized?(channel_id, user_id)
        return true if user_id == @authority.owner

        @store.members(channel_id).any? { |member| @authority.human_role(user_id, member) }
      end

      def react_offline(message)
        @slack.add_reaction(channel: message[:channel_id], ts: message[:ts], name: "zzz")
      rescue Slack::Client::Error => e
        Agents.report("zzz reaction failed for #{message[:channel_id]}/#{message[:ts]}: #{e.message}")
      end
    end
  end
end

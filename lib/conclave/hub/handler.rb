# frozen_string_literal: true

module Conclave
  module Hub
    # Executes one socket request on behalf of a connection. Every call runs under the hub lock.
    # Ops always act as the agent the connection registered; only `forget` names an agent.
    class Handler
      BadRequest = Class.new(StandardError)
      Refusal = Class.new(StandardError)

      OPS = %w[register send_message get_thread list_channels list_agents forget].freeze
      UNREGISTERED_OPS = %w[register forget].freeze
      BAD_REQUEST = { ok: false, error: "bad request" }.freeze

      # rubocop:disable-next Metrics/ParameterLists
      def initialize(agents:, store:, slack:, authority:, epic_channels:, bot_id:, lock:)
        @agents = agents
        @store = store
        @slack = slack
        @epic_channels = epic_channels
        @lock = lock
        @channel_names = ChannelNames.new(slack)
        @thread_filter = ThreadFilter.new(authority: authority, bot_id: bot_id, store: store)
        @registered = {}
      end

      def call(request, connection)
        return BAD_REQUEST unless RequestCheck.well_formed?(request)

        id = request["id"]
        body = @lock.synchronize { dispatch(request, connection) }
        { id: id, ok: true }.compact.merge(body)
      rescue BadRequest
        { id: id, ok: false, error: "bad request" }.compact
      rescue Refusal, Slack::Client::Error => e
        { id: id, ok: false, error: e.message }.compact
      rescue StandardError => e
        Agents.report("handler error on #{request['op']}: #{e.class}: #{e.message}")
        { id: id, ok: false, error: "internal error" }.compact
      end

      def disconnected(connection)
        @lock.synchronize do
          agent = @registered.delete(connection)
          @agents.unregister(agent) if agent
        end
      end

      private

      def dispatch(request, connection)
        op = request["op"]
        raise BadRequest unless OPS.include?(op)

        agent = @registered[connection]
        raise Refusal, "not registered" unless agent || UNREGISTERED_OPS.include?(op)

        send("op_#{op}", request, connection, agent)
      end

      def op_register(request, connection, _agent)
        raise Refusal, "already registered" if @registered.key?(connection)

        name = string!(request, "agent")
        raise Refusal, "name_taken" if @agents.register(name, connection) == :name_taken

        @registered[connection] = name
        join_epic(name)
        {}
      end

      def op_forget(request, _connection, _agent)
        name = string!(request, "agent")
        raise Refusal, "agent online" if @agents.online?(name)

        @store.forget(name)
        @registered.delete_if { |_connection, registered| registered == name }
        {}
      end

      def op_send_message(request, _connection, agent)
        channel_id = resolve_channel(agent, string!(request, "channel"))
        @agents.post(agent: agent, channel_id: channel_id, text: string!(request, "text"),
                     thread_ts: optional_string(request, "thread_ts"),
                     in_reply_to_ts: optional_string(request, "in_reply_to_ts"))
      end

      def op_get_thread(request, _connection, agent)
        channel_id = resolve_channel(agent, string!(request, "channel"))
        thread_ts = string!(request, "thread_ts")
        replies = @slack.replies(channel: channel_id, ts: thread_ts)
        { messages: replies.fetch("messages", []).map { |message| @thread_filter.call(message, agent, channel_id) } }
      end

      def op_list_channels(_request, _connection, agent)
        { channels: @store.memberships(agent).map { |id| { id: id, name: @channel_names[id] } } }
      end

      def op_list_agents(request, _connection, agent)
        channel_id = resolve_channel(agent, string!(request, "channel"))
        { agents: @store.members(channel_id).map { |name| { name: name, online: @agents.online?(name) } } }
      end

      def join_epic(name)
        @epic_channels.ensure_joined(name)
      rescue StandardError => e
        Agents.report("epic join failed for #{name}: #{e.class}: #{e.message}")
      end

      def resolve_channel(agent, channel)
        ids = @store.memberships(agent)
        return channel if ids.include?(channel)

        name = channel.delete_prefix("#")
        ids.find { |id| @channel_names[id] == name } || raise(Refusal, "not a member of #{channel}")
      end

      def string!(request, key)
        value = request[key]
        raise BadRequest unless value.is_a?(String) && !value.empty?

        value
      end

      def optional_string(request, key)
        value = request[key]
        raise BadRequest unless value.nil? || value.is_a?(String)

        value
      end
    end
  end
end

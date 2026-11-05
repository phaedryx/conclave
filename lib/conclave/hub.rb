# frozen_string_literal: true

require "fileutils"
require "socket"

module Conclave
  # The hub process: wires the store, Slack and Shortcut clients, routing, the agent socket server and
  # Socket Mode together. One Mutex serializes every Slack callback, socket request and the startup backfill.
  class Hub # rubocop:disable Metrics/ClassLength
    ConfigError = Class.new(StandardError)
    AlreadyRunning = Class.new(StandardError)
    AppTokenRejected = Class.new(StandardError)

    REQUIRED = %w[bot_token app_token owner_user_id shortcut_token].freeze
    BACKFILL_LIMIT = 200
    SHUTDOWN_JOIN_TIMEOUT = 2

    attr_reader :store, :agents, :router

    # Best-effort `conclave forget`: returns the line to print. Never raises; a missing hub is not an error.
    def self.forget_remote(name, path:)
      socket = UNIXSocket.new(path)
      Protocol.write(socket, { id: 1, op: "forget", agent: name })
      reply = Protocol.read(socket)
      return "conclave: hub closed the connection without answering" unless reply

      reply["ok"] ? "conclave: forgot #{name}" : "conclave: not forgotten: #{reply['error']}"
    rescue SystemCallError, IOError, JSON::ParserError, Protocol::LineTooLong
      "conclave: hub not running at #{path}; nothing to forget"
    ensure
      socket&.close
    end

    def initialize(config:)
      @config = config
      validate!(config)
      @lock = Mutex.new
      @stopper = Thread::Queue.new
      @slack = Slack::Client.new(token: config.bot_token)
      auth = @slack.auth_test
      @bot_user = auth["user"]
      FileUtils.mkdir_p(config.home, mode: 0o700)
      @store = Store.new(config.db_path)
      build_components(config, auth["bot_id"])
    end

    def synchronize(&) = @lock.synchronize(&)

    # Raises AlreadyRunning when something answers on the hub socket; a missing or stale socket is fine.
    def ensure_not_running!
      UNIXSocket.new(@config.socket_path).close
      raise AlreadyRunning, "hub already running at #{@config.socket_path}"
    rescue Errno::ENOENT, Errno::ECONNREFUSED
      nil
    end

    # Replays messages missed while the hub was down through the same rules as live ones. Takes the hub lock
    # itself, so it can never run unserialized.
    def backfill
      synchronize do
        @store.channels_with_last_seen.each do |channel, last_seen|
          backfill_channel(channel, last_seen)
        rescue StandardError => e
          warn "conclave: backfill #{channel} failed: #{e.class}: #{e.message}"
        end
      end
    end

    # Blocks until INT/TERM or until Slack rejects the app token (then raises AppTokenRejected after shutdown).
    def run
      ensure_not_running! # before any teardown can run: stopping Server would unlink a live hub's socket
      previous = %w[INT TERM].to_h { |signal| [signal, trap(signal) { @stopper << signal }] }
      reason = begin
        @server.start
        backfill
        @socket_mode.start
        @stopper.pop
      ensure
        previous.each { |signal, handler| trap(signal, handler) }
        shutdown
      end
      raise AppTokenRejected, "Slack app token rejected: #{reason.message}" if reason.is_a?(Exception)
    end

    # Idempotent. Stops Socket Mode and the agent server (joining its reader threads) before closing the store.
    def shutdown
      return if @shut_down

      @shut_down = true
      @socket_mode&.stop
      @server&.stop(timeout: SHUTDOWN_JOIN_TIMEOUT)
      synchronize { @store&.close }
    end

    private

    def validate!(config)
      blank = REQUIRED.select { |key| config.public_send(key).to_s.strip.empty? }
      raise ConfigError, "config is missing: #{blank.join(', ')}" unless blank.empty?
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def build_components(config, bot_id)
      authority = Authority.new(owner: config.owner_user_id, store: @store)
      @agents = Agents.new(store: @store, authority: authority, slack: @slack,
                           loop_guard_limit: config.loop_guard_limit, queue_limit: config.offline_queue_limit)
      commands = Commands.new(store: @store, authority: authority, slack: @slack, owner: config.owner_user_id)
      @router = Router.new(agents: @agents, authority: authority, store: @store, slack: @slack, bot_id: bot_id,
                           commands: commands)
      shortcut = Shortcut::Client.new(token: config.shortcut_token)
      epics = EpicChannels.new(store: @store, slack: @slack, shortcut: shortcut, owner: config.owner_user_id)
      handler = Handler.new(agents: @agents, store: @store, slack: @slack, authority: authority,
                            epic_channels: epics, bot_id: bot_id, lock: @lock)
      @server = Server.new(path: config.socket_path, handler: handler)
      @socket_mode = Slack::SocketMode.new(
        slack: Slack::Client.new(token: config.app_token),
        on_event: ->(event) { synchronize { @router.handle_message(event) } },
        on_slash: ->(payload) { synchronize { commands.handle_slash(payload) } },
        on_connected: method(:announce_connected),
        on_fatal: ->(error) { @stopper << error }
      )
    end

    def announce_connected
      return if @announced

      @announced = true
      warn "connected to Slack as #{@bot_user}"
    end

    def backfill_channel(channel, last_seen)
      messages = @slack.history(channel: channel, oldest: last_seen, limit: BACKFILL_LIMIT)["messages"] || []
      messages.reverse_each do |message|
        next if message["ts"] == last_seen

        @router.handle_message({ "channel" => channel }.merge(message))
      end
    end
  end
end

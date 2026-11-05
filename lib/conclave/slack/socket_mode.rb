# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "json"

module Conclave
  module Slack
    # Slack Socket Mode client. `handle_envelope` is pure routing and ack-building; `run` owns the websocket loop,
    # reconnecting on disconnect envelopes, EOF and errors. Handlers must never kill the loop.
    class SocketMode # rubocop:disable Metrics/ClassLength
      BACKOFF_MAX = 30
      HEALTHY_AFTER = 10
      # Disconnect reasons that are routine rotations rather than failures: reconnect at once, backoff untouched.
      PROMPT_RECONNECT_REASONS = %w[refresh_requested warning].freeze
      SLASH_FAILURE = "Something went wrong."

      # What one connection attempt did: whether it delivered real work, when it started, and whether the server
      # asked for a prompt reconnect.
      Attempt = Struct.new(:started, :delivered, :prompt)

      # rubocop:disable-next Metrics/ParameterLists
      def initialize(slack:, on_event:, on_slash:, on_connected: nil, on_fatal: nil, backoff_base: 1,
                     healthy_after: HEALTHY_AFTER, log: method(:warn), connect: method(:websocket_connect),
                     sleeper: ->(seconds) { sleep(seconds) },
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @slack = slack
        @on_event = on_event
        @on_slash = on_slash
        @on_connected = on_connected
        @on_fatal = on_fatal
        @backoff_base = backoff_base
        @healthy_after = healthy_after
        @log = log
        @connect = connect
        @sleeper = sleeper
        @clock = clock
        @stopping = false
      end

      def reconnect?(envelope) = envelope["type"] == "disconnect"

      # Returns the ack Hash, or nil when there is nothing to ack. When a block is given, event acks are
      # yielded before the handler runs (and nil is returned) so a slow handler never delays Slack's ack.
      def handle_envelope(envelope)
        return if envelope["type"] == "hello" || !(envelope["payload"] && envelope["envelope_id"])
        return slash_ack(envelope) if envelope["type"] == "slash_commands"

        ack = { envelope_id: envelope["envelope_id"] }
        yield ack if block_given?
        dispatch_event(envelope)
        ack unless block_given?
      end

      # A connection is healthy (resets the backoff) only if it delivered an envelope other than hello/disconnect,
      # or stayed up for healthy_after seconds. A routine disconnect (refresh/warning) reconnects at once. Anything
      # else waits out the backoff. An app token the server rejects ends the loop (on_fatal is told).
      def run
        delay = @backoff_base
        until @stopping
          attempt = run_connection
          return if @fatal

          delay = @backoff_base if healthy?(attempt)
          next if @stopping || attempt.prompt

          @sleeper.call(delay)
          delay = [delay * 2, BACKOFF_MAX].min
        end
      end

      def start = (@thread = Thread.new { run })

      def stop # rubocop:disable Naming/PredicateMethod
        @stopping = true
        @thread&.kill
        @thread&.join(1)
        true
      end

      private

      def healthy?(attempt) = attempt.delivered || @clock.call - attempt.started >= @healthy_after

      # One connection attempt; errors are logged. Returns the Attempt either way.
      def run_connection
        attempt = Attempt.new(@clock.call, false, false)
        connect_once(attempt)
        attempt
      rescue Client::AuthenticationError => e
        @fatal = e
        @log.call("conclave: socket mode: #{e.message}")
        @on_fatal&.call(e)
        attempt
      rescue StandardError => e
        @log.call("conclave: socket mode: #{e.class}: #{e.message}")
        attempt
      end

      def connect_once(attempt)
        url = @slack.open_socket_connection
        Sync do
          @connect.call(url) do |connection|
            @on_connected&.call
            while (text = connection.read) && !@stopping
              break if process(connection, text, attempt)
            end
          end
        end
      end

      # True when the connection should end because the server sent a disconnect.
      def process(connection, text, attempt)
        envelope = JSON.parse(text)
        return false if envelope["type"] == "hello"

        if reconnect?(envelope)
          note_disconnect(envelope, attempt)
          return true
        end

        attempt.delivered = true
        ack = handle_envelope(envelope) { |early| connection.write(JSON.generate(early)) }
        connection.write(JSON.generate(ack)) if ack
        false
      rescue JSON::ParserError => e
        @log.call("conclave: socket mode: bad frame: #{e.message}")
        false
      end

      def note_disconnect(envelope, attempt)
        attempt.prompt = PROMPT_RECONNECT_REASONS.include?(envelope["reason"])
      end

      def slash_ack(envelope)
        text = begin
          @on_slash.call(envelope["payload"])
        rescue StandardError => e
          @log.call("conclave: slash handler error: #{e.class}: #{e.message}")
          SLASH_FAILURE
        end
        { envelope_id: envelope["envelope_id"], payload: { text: text } }
      end

      def dispatch_event(envelope)
        event = envelope["payload"]["event"]
        @on_event.call(event) if envelope["type"] == "events_api" && event.is_a?(Hash) && event["type"] == "message"
      rescue StandardError => e
        @log.call("conclave: event handler error: #{e.class}: #{e.message}")
      end

      def websocket_connect(url, &)
        endpoint = Async::HTTP::Endpoint.parse(url)
        Async::WebSocket::Client.connect(endpoint) do |connection|
          yield WebSocketAdapter.new(connection)
        end
      end

      # Gives the websocket connection the minimal read/write(String) surface the loop uses.
      class WebSocketAdapter
        def initialize(connection)
          @connection = connection
        end

        def read = @connection.read&.to_str

        def write(text)
          @connection.write(::Protocol::WebSocket::TextMessage.new(text))
          @connection.flush
        end
      end
    end
  end
end

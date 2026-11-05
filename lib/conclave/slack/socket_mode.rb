# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "json"

module Conclave
  module Slack
    # Slack Socket Mode client. `handle_envelope` is pure routing and ack-building; `run` owns the websocket loop,
    # reconnecting on disconnect envelopes, EOF and errors. Handlers must never kill the loop.
    class SocketMode
      BACKOFF_MAX = 30
      SLASH_FAILURE = "Something went wrong."

      # rubocop:disable-next Metrics/ParameterLists
      def initialize(slack:, on_event:, on_slash:, on_connected: nil, backoff_base: 1, log: method(:warn),
                     connect: method(:websocket_connect), sleeper: ->(seconds) { sleep(seconds) })
        @slack = slack
        @on_event = on_event
        @on_slash = on_slash
        @on_connected = on_connected
        @backoff_base = backoff_base
        @log = log
        @connect = connect
        @sleeper = sleeper
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

      def run
        delay = @backoff_base
        until @stopping
          if run_connection
            delay = @backoff_base
            next
          end
          next if @stopping

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

      # One connection attempt. True when it was healthy (at least one frame arrived); errors are logged.
      def run_connection
        connect_once
      rescue StandardError => e
        @log.call("conclave: socket mode: #{e.class}: #{e.message}")
        false
      end

      def connect_once
        url = @slack.open_socket_connection
        received = false
        Sync do
          @connect.call(url) do |connection|
            @on_connected&.call
            while (text = connection.read) && !@stopping
              received = true
              break if process(connection, text)
            end
          end
        end
        received
      end

      # True when the server asked us to reconnect.
      def process(connection, text)
        envelope = JSON.parse(text)
        return false if envelope["type"] == "hello"
        return true if reconnect?(envelope)

        ack = handle_envelope(envelope) { |early| connection.write(JSON.generate(early)) }
        connection.write(JSON.generate(ack)) if ack
        false
      rescue JSON::ParserError => e
        @log.call("conclave: socket mode: bad frame: #{e.message}")
        false
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

# frozen_string_literal: true

require "socket"

module Conclave
  module Channel
    HubUnavailable = Class.new(StandardError)
    RequestTimeout = Class.new(HubUnavailable)

    # The hub refused registration because another session holds the name.
    class NameTaken < HubUnavailable
      def initialize(agent) = super("name #{agent} is already online")
    end

    # In-flight requests: one queue per id, answered by the reader or failed wholesale on disconnect.
    class PendingRequests
      def initialize
        @lock = Mutex.new
        @queues = {}
        @next_id = 0
      end

      def add
        queue = Thread::Queue.new
        id = @lock.synchronize { (@next_id += 1).tap { |next_id| @queues[next_id] = queue } }
        [id, queue]
      end

      def answer(request_id, message) = @lock.synchronize { @queues[request_id] }&.push(message)

      def release(request_id) = @lock.synchronize { @queues.delete(request_id) }

      def fail_all = @lock.synchronize { @queues.each_value { |queue| queue.push(:lost) } }
    end

    # Reads one socket until EOF or error. Deliver pushes go to on_deliver whenever they arrive (even before the
    # register response); everything else is a response, matched to its request by id.
    class SocketReader
      def initialize(socket, pending, on_deliver)
        @socket = socket
        @pending = pending
        @on_deliver = on_deliver
      end

      def run
        while (message = Protocol.read(@socket))
          route(message)
        end
      rescue StandardError => e
        warn("conclave: hub read failed: #{e.class}: #{e.message}")
      end

      private

      def route(message)
        return unless message.is_a?(Hash)

        if message["op"] == "deliver"
          deliver(message["message"])
        else
          @pending.answer(message["id"], message)
        end
      end

      def deliver(payload)
        @on_deliver.call(payload)
      rescue StandardError => e
        warn("conclave: deliver failed: #{e.class}: #{e.message}")
      end
    end

    # The current socket and whether it has registered. Only the connection that owns the current socket may change
    # state; a stale reader must not clobber a newer one.
    class SocketState
      attr_reader :socket

      def initialize(pending)
        @pending = pending
        @lock = Mutex.new
        @socket = nil
        @registered = false
      end

      def registered? = @registered

      def adopt(socket) = @lock.synchronize { @socket = socket }

      def mark_registered(socket)
        @lock.synchronize { @registered = true if @socket.equal?(socket) }
      end

      def release(socket)
        @lock.synchronize do
          next unless @socket.equal?(socket)

          @registered = false
          @socket = nil
          @pending.fail_all
        end
      end
    end

    # Client side of the hub socket. A background thread connects, registers and reads; it reconnects with
    # exponential backoff for as long as it runs. Responses are matched to requests by id, and deliver pushes go
    # to on_deliver from the reader thread, whenever they arrive. Logs only to stderr.
    class HubConnection
      MAX_DELAY = 30
      REQUEST_TIMEOUT = 10

      attr_reader :agent

      # rubocop:disable-next Metrics/ParameterLists
      def initialize(path:, agent:, on_deliver:, base_delay: 1, max_delay: MAX_DELAY, request_timeout: REQUEST_TIMEOUT)
        @path = path
        @agent = agent
        @on_deliver = on_deliver
        @base_delay = base_delay
        @max_delay = max_delay
        @request_timeout = request_timeout
        @pending = PendingRequests.new
        @write_lock = Mutex.new
        @state = SocketState.new(@pending)
      end

      def start
        @thread = Thread.new { run }
        self
      end

      def stop
        @thread&.kill&.join(1)
        disconnect(@state.socket)
      end

      def registered? = @state.registered?

      # Raises HubUnavailable while disconnected or when the connection drops, RequestTimeout after the timeout, and
      # NameTaken while the hub refuses the name because another session holds it.
      def request(operation, **fields)
        raise(@refusal == "name_taken" ? NameTaken.new(@agent) : HubUnavailable.new("not connected")) unless registered?

        roundtrip(operation, fields)
      end

      private

      def run
        delay = @base_delay
        loop do
          delay = @base_delay if safe_session
          sleep delay
          delay = [delay * 2, @max_delay].min
        end
      end

      # A session that fails unexpectedly is logged and treated as a failed attempt, so the loop backs off and retries.
      def safe_session
        session
      rescue StandardError => e
        log("hub session failed: #{e.class}: #{e.message}")
        false
      end

      # One connect/register/read cycle. True when registration succeeded.
      def session
        @refusal = nil
        socket = UNIXSocket.new(@path)
        @state.adopt(socket)
        reader = Thread.new { read(socket) }
        registered = register(socket)
        reader.join if registered
        registered
      ensure
        reader&.kill
        disconnect(socket)
      end

      def read(socket)
        SocketReader.new(socket, @pending, @on_deliver).run
      ensure
        disconnect(socket)
      end

      # Remembers a refusal until the next attempt, so requests can tell a refused name from a down hub.
      def register(socket)
        response = roundtrip("register", { agent: @agent })
        @refusal = response["error"] unless response["ok"]
        if response["ok"] && mark_registered(socket)
          log("registered as #{@agent}")
          true
        else
          log("register failed for #{@agent}: #{response['error']}")
          false
        end
      rescue HubUnavailable => e
        log("register failed for #{@agent}: #{e.message}")
        false
      end

      def mark_registered(socket) = @state.mark_registered(socket)

      def roundtrip(operation, fields)
        id, queue = @pending.add
        send_request(id, operation, fields)
        result = queue.pop(timeout: @request_timeout)
        raise RequestTimeout, "hub did not answer #{operation}" if result.nil?
        raise HubUnavailable, "hub connection lost" if result == :lost

        result
      ensure
        @pending.release(id)
      end

      def send_request(request_id, operation, fields)
        socket = @state.socket or raise HubUnavailable, "not connected"
        @write_lock.synchronize { Protocol.write(socket, fields.merge(id: request_id, op: operation.to_s)) }
      rescue IOError, SystemCallError => e
        raise HubUnavailable, "write failed: #{e.message}"
      end

      def disconnect(socket)
        @state.release(socket)
        close_quietly(socket)
      end

      def close_quietly(socket)
        socket.close unless socket.nil? || socket.closed?
      rescue IOError, SystemCallError
        nil
      end

      def log(text) = warn("conclave: #{text}")
    end
  end
end

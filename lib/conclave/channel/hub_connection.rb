# frozen_string_literal: true

require "socket"

module Conclave
  module Channel
    HubUnavailable = Class.new(StandardError)
    RequestTimeout = Class.new(HubUnavailable)

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
      ERRORS = [IOError, SystemCallError, JSON::ParserError, EncodingError, Protocol::LineTooLong].freeze

      def initialize(socket, pending, on_deliver)
        @socket = socket
        @pending = pending
        @on_deliver = on_deliver
      end

      def run
        while (message = Protocol.read(@socket))
          route(message)
        end
      rescue *ERRORS => e
        warn("conclave: hub read failed: #{e.class}: #{e.message}")
      end

      private

      def route(message)
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
        @socket = nil
        @registered = false
      end

      def start
        @thread = Thread.new { run }
        self
      end

      def stop
        @thread&.kill&.join(1)
        disconnect(@socket)
      end

      def registered? = @registered

      # Raises HubUnavailable while disconnected or when the connection drops, RequestTimeout after the timeout.
      def request(operation, **fields)
        raise HubUnavailable, "not connected" unless @registered

        roundtrip(operation, fields)
      end

      private

      def run
        delay = @base_delay
        loop do
          delay = @base_delay if session
          sleep delay
          delay = [delay * 2, @max_delay].min
        end
      end

      # One connect/register/read cycle. True when registration succeeded.
      def session
        socket = UNIXSocket.new(@path)
        @socket = socket
        reader = Thread.new { read(socket) }
        registered = register
        reader.join if registered
        registered
      rescue SystemCallError, IOError => e
        log("hub connection failed: #{e.class}: #{e.message}")
        false
      ensure
        reader&.kill
        disconnect(socket)
      end

      def read(socket)
        SocketReader.new(socket, @pending, @on_deliver).run
      ensure
        disconnect(socket)
      end

      def register
        response = roundtrip("register", { agent: @agent })
        if response["ok"]
          @registered = true
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
        socket = @socket or raise HubUnavailable, "not connected"
        @write_lock.synchronize { Protocol.write(socket, { id: request_id, op: operation.to_s }.merge(fields)) }
      rescue IOError, SystemCallError => e
        raise HubUnavailable, "write failed: #{e.message}"
      end

      # Only the connection that owns the current socket may clear state; a stale reader must not clobber a newer one.
      def disconnect(socket)
        if @socket.equal?(socket)
          @registered = false
          @socket = nil
          @pending.fail_all
        end
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

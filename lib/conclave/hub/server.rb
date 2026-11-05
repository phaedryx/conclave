# frozen_string_literal: true

require "fileutils"
require "socket"

module Conclave
  class Hub
    # Unix-socket NDJSON server. One reader thread per client; the handler serializes work under the hub lock.
    class Server
      # What the handler sees as an agent's connection. Responses and deliveries only enqueue on a bounded
      # outbox; a writer thread per connection does the socket I/O, so a slow client never blocks the hub.
      # A failed write or an overflowing outbox closes the socket, which ends the reader and so goes through
      # Handler#disconnected.
      class Connection
        OUTBOX_LIMIT = 1000
        FLUSH_TIMEOUT = 1

        def initialize(socket)
          @socket = socket
          @outbox = Thread::Queue.new
          @writer = Thread.new { drain_outbox }
        end

        def deliver(message) = write({ op: "deliver", message: message })

        def closed? = @outbox.closed?

        # Never blocks. True when queued, false when the connection is closed or just overflowed.
        def write(hash)
          return false if @outbox.closed?

          if @outbox.size >= OUTBOX_LIMIT
            Agents.report("client outbox overflow; closing connection")
            close
            return false
          end
          @outbox.push(hash)
          true
        rescue ClosedQueueError
          false
        end

        # flush: true lets the writer finish what is queued (bounded wait) before the socket closes.
        def close(flush: false)
          @outbox.close
          @writer.join(FLUSH_TIMEOUT) if flush && Thread.current != @writer
          close_socket
        end

        private

        def drain_outbox
          while (hash = @outbox.pop)
            send_one(hash)
          end
        rescue IOError, SystemCallError => e
          Agents.report("write to client failed: #{e.message}")
          close
        end

        def send_one(hash)
          Protocol.write(@socket, hash)
        rescue JSON::GeneratorError, EncodingError => e
          Agents.report("dropped unserializable message: #{e.message}")
          send_fallback(hash)
        end

        # Tells the client its request failed, when the id alone can be serialized.
        def send_fallback(hash)
          id = hash[:id]
          return unless id.is_a?(Integer) || (id.is_a?(String) && id.valid_encoding?)

          Protocol.write(@socket, { id: id, ok: false, error: "internal error" })
        rescue JSON::GeneratorError, EncodingError
          nil
        end

        def close_socket
          return if @socket.closed?

          begin
            @socket.shutdown
          rescue SystemCallError, IOError
            nil
          end
          @socket.close unless @socket.closed?
        rescue IOError
          nil
        end
      end

      BAD_REQUEST = { ok: false, error: "bad request" }.freeze
      ACCEPT_RETRY_DELAY = 0.1

      def initialize(path:, handler:)
        @path = path
        @handler = handler
        @connections = []
        @connections_lock = Mutex.new
        @stopping = false
      end

      def start
        prepare_path
        @server = listen
        File.chmod(0o600, @path)
        @accept_thread = Thread.new { accept_loop }
        self
      end

      def stop
        @stopping = true
        @server&.close
        @accept_thread&.join(1)
        @connections_lock.synchronize { @connections.dup }.each(&:close)
        File.delete(@path) if File.socket?(@path)
      end

      private

      # The socket file is created owner-only from the start; chmod afterwards is belt and braces.
      def listen
        old = File.umask(0o177)
        UNIXServer.new(@path)
      ensure
        File.umask(old)
      end

      def prepare_path
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir, mode: 0o700) unless File.directory?(dir)
        File.delete(@path) if File.socket?(@path)
      end

      # Ends only when the server is closed or stopping; any other accept error is logged and retried.
      def accept_loop
        until @stopping
          begin
            socket = @server.accept
          rescue StandardError => e
            break if @stopping || @server.closed?

            Agents.report("accept failed: #{e.class}: #{e.message}")
            sleep ACCEPT_RETRY_DELAY
            next
          end
          spawn_serve(socket)
        end
      end

      def spawn_serve(socket)
        Thread.new(socket) { |client| serve(client) }
      rescue StandardError => e
        Agents.report("could not start client thread: #{e.class}: #{e.message}")
        socket.close unless socket.closed?
        sleep ACCEPT_RETRY_DELAY
      end

      def serve(socket)
        connection = Connection.new(socket)
        @connections_lock.synchronize { @connections << connection }
        while (request = read_request(socket))
          connection.write(request.is_a?(Symbol) ? BAD_REQUEST : @handler.call(request, connection))
          break if request == :too_long
        end
      rescue IOError, SystemCallError, JSON::GeneratorError
        nil
      ensure
        finish(connection) if connection
      end

      # Flush and close first, then unregister; a raise in one must not skip the other.
      def finish(connection)
        begin
          connection.close(flush: true)
        rescue StandardError => e
          Agents.report("closing connection failed: #{e.class}: #{e.message}")
        end
        begin
          @handler.disconnected(connection)
        rescue StandardError => e
          Agents.report("disconnect handling failed: #{e.class}: #{e.message}")
        end
        @connections_lock.synchronize { @connections.delete(connection) }
      end

      # nil at EOF, :bad for an unparseable line, :too_long (answered, then dropped) for an oversized one.
      def read_request(socket)
        Protocol.read(socket)
      rescue JSON::ParserError, EncodingError
        :bad
      rescue Protocol::LineTooLong
        :too_long
      end
    end
  end
end

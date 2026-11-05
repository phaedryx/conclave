# frozen_string_literal: true

require "fileutils"
require "socket"

module Conclave
  module Hub
    # Unix-socket NDJSON server. One thread per client; the handler serializes work under the hub lock.
    class Server
      # What the handler sees as an agent's connection. Writes are serialized per connection because
      # responses and deliveries come from different threads.
      class Connection
        def initialize(socket)
          @socket = socket
          @write_lock = Mutex.new
        end

        def deliver(message) = write({ op: "deliver", message: message })

        def write(hash)
          @write_lock.synchronize { Protocol.write(@socket, hash) }
        rescue IOError, SystemCallError => e
          Agents.report("write to client failed: #{e.message}")
        end

        def close
          @socket.close unless @socket.closed?
        end
      end

      BAD_REQUEST = { ok: false, error: "bad request" }.freeze

      def initialize(path:, handler:)
        @path = path
        @handler = handler
        @connections = []
        @connections_lock = Mutex.new
      end

      def start
        prepare_path
        @server = UNIXServer.new(@path)
        File.chmod(0o600, @path)
        @accept_thread = Thread.new { accept_loop }
        self
      end

      def stop
        @server&.close
        @accept_thread&.join(1)
        @connections_lock.synchronize { @connections.dup }.each(&:close)
        File.delete(@path) if File.socket?(@path)
      end

      private

      def prepare_path
        dir = File.dirname(@path)
        FileUtils.mkdir_p(dir, mode: 0o700) unless File.directory?(dir)
        File.delete(@path) if File.socket?(@path)
      end

      def accept_loop
        loop do
          socket = @server.accept
          Thread.new(socket) { |client| serve(client) }
        end
      rescue IOError, SystemCallError
        nil
      end

      def serve(socket)
        connection = Connection.new(socket)
        @connections_lock.synchronize { @connections << connection }
        while (request = read_request(socket))
          connection.write(request == :bad ? BAD_REQUEST : @handler.call(request, connection))
        end
      rescue IOError, SystemCallError
        nil
      ensure
        @handler.disconnected(connection) if connection
        @connections_lock.synchronize { @connections.delete(connection) }
        connection&.close
      end

      # nil at EOF, :bad for an unparseable line.
      def read_request(socket)
        Protocol.read(socket)
      rescue JSON::ParserError
        :bad
      end
    end
  end
end

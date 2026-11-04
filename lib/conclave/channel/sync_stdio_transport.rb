# frozen_string_literal: true

require "mcp"

module Conclave
  module Channel
    # StdioTransport writes to $stdout without a lock. Notifications pushed from a
    # background thread could interleave with responses, so serialize every write.
    class SyncStdioTransport < MCP::Server::Transports::StdioTransport
      def initialize(server)
        super
        @write_lock = Mutex.new
      end

      def send_response(message)
        @write_lock.synchronize { super }
      end
    end
  end
end

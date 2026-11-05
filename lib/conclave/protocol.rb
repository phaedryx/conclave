# frozen_string_literal: true

require "json"

module Conclave
  # Newline-delimited JSON over a stream socket.
  module Protocol
    def self.write(stream, hash)
      stream.write("#{JSON.generate(hash)}\n")
    end

    # nil at EOF. Raises JSON::ParserError on a malformed line.
    def self.read(stream)
      line = stream.gets
      line && JSON.parse(line)
    end
  end
end

# frozen_string_literal: true

require "json"

module Conclave
  # Newline-delimited JSON over a stream socket.
  module Protocol
    MAX_LINE = 1_048_576
    LineTooLong = Class.new(StandardError)

    def self.write(stream, hash)
      stream.write("#{JSON.generate(hash)}\n")
    end

    # nil at EOF. Raises JSON::ParserError on a malformed line and LineTooLong past MAX_LINE bytes.
    def self.read(stream)
      line = stream.gets(MAX_LINE + 1)
      return unless line
      raise LineTooLong if line.bytesize > MAX_LINE

      JSON.parse(line)
    end
  end
end

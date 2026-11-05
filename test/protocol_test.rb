# frozen_string_literal: true

require "test_helper"
require "stringio"

class ProtocolTest < Minitest::Test
  def test_write_and_read_round_trip
    io = StringIO.new
    Conclave::Protocol.write(io, { op: "register", agent: "a" })
    assert_equal "{\"op\":\"register\",\"agent\":\"a\"}\n", io.string
    assert_equal({ "op" => "register", "agent" => "a" }, Conclave::Protocol.read(StringIO.new(io.string)))
  end

  def test_read_returns_nil_at_eof
    assert_nil Conclave::Protocol.read(StringIO.new(""))
  end

  def test_read_raises_on_malformed_json
    assert_raises(JSON::ParserError) { Conclave::Protocol.read(StringIO.new("{nope\n")) }
  end
end

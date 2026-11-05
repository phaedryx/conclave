# frozen_string_literal: true

require "test_helper"

class SocketModeTest < Minitest::Test
  class FakeConnection
    attr_reader :sent

    def initialize(frames)
      @frames = frames.dup
      @sent = []
    end

    def read = @frames.shift.then { |frame| frame.respond_to?(:call) ? frame.call : frame }

    def write(text) = @sent << JSON.parse(text)
  end

  def setup
    @events = []
    @slashes = []
    @errors = []
    @slack = Object.new
    def @slack.open_socket_connection = "wss://example.test/link"
    @mode = build
  end

  def build(**overrides)
    Conclave::Slack::SocketMode.new(
      slack: @slack,
      on_event: ->(event) { @events << event },
      on_slash: lambda { |payload|
        @slashes << payload
        "done"
      },
      log: ->(line) { @errors << line },
      **overrides
    )
  end

  def events_api(event, envelope_id: "E1")
    { "type" => "events_api", "envelope_id" => envelope_id, "payload" => { "event" => event } }
  end

  def test_events_api_envelope_acked_and_routed
    ack = @mode.handle_envelope(events_api({ "type" => "message", "text" => "hi" }))
    assert_equal({ envelope_id: "E1" }, ack)
    assert_equal [{ "type" => "message", "text" => "hi" }], @events
  end

  def test_non_message_events_are_acked_but_not_routed
    ack = @mode.handle_envelope(events_api({ "type" => "reaction_added" }))
    assert_equal({ envelope_id: "E1" }, ack)
    assert_empty @events
  end

  def test_slash_envelope_acked_with_response_text
    envelope = { "type" => "slash_commands", "envelope_id" => "S1", "payload" => { "text" => "invite a" } }
    ack = @mode.handle_envelope(envelope)
    assert_equal({ envelope_id: "S1", payload: { text: "done" } }, ack)
    assert_equal [{ "text" => "invite a" }], @slashes
  end

  def test_slash_handler_error_still_acks
    mode = build(on_slash: ->(_payload) { raise "boom" })
    envelope = { "type" => "slash_commands", "envelope_id" => "S1", "payload" => {} }
    ack = mode.handle_envelope(envelope)
    assert_equal "S1", ack[:envelope_id]
    assert_match(/went wrong/, ack[:payload][:text])
    assert_match(/boom/, @errors.join)
  end

  def test_event_acked_before_handling_and_handler_error_does_not_raise
    order = []
    mode = build(on_event: lambda { |_event|
      order << :handled
      raise "boom"
    })
    result = mode.handle_envelope(events_api({ "type" => "message" })) { |ack| order << [:acked, ack] }
    assert_nil result
    assert_equal [[:acked, { envelope_id: "E1" }], :handled], order
    assert_match(/boom/, @errors.join)
  end

  def test_envelope_without_payload_is_not_acked
    assert_nil @mode.handle_envelope({ "type" => "hello" })
  end

  def test_hello_is_ignored
    assert_nil @mode.handle_envelope({ "type" => "hello", "envelope_id" => "H1", "payload" => {} })
    assert_empty @events
  end

  def test_disconnect_envelope_requests_reconnect
    envelope = { "type" => "disconnect", "reason" => "refresh_requested" }
    assert @mode.reconnect?(envelope)
    assert_nil @mode.handle_envelope(envelope)
    refute @mode.reconnect?(events_api({ "type" => "message" }))
  end

  def test_run_acks_frames_and_reconnects_after_disconnect
    first = FakeConnection.new([
                                 JSON.generate({ "type" => "hello" }),
                                 JSON.generate(events_api({ "type" => "message", "text" => "a" })),
                                 JSON.generate({ "type" => "disconnect" })
                               ])
    second = FakeConnection.new([JSON.generate(events_api({ "type" => "message", "text" => "b" }, envelope_id: "E2"))])
    connections = [first, second]
    mode = build(connect: lambda { |_url, &blk|
      next mode.stop if connections.empty?

      blk.call(connections.shift)
    })
    mode.run
    assert_equal [{ "envelope_id" => "E1" }], first.sent
    assert_equal [{ "envelope_id" => "E2" }], second.sent
    assert_equal(%w[a b], @events.map { |event| event["text"] })
  end

  def test_run_survives_malformed_frames
    conn = FakeConnection.new(["not json", JSON.generate(events_api({ "type" => "message" }))])
    mode = build(connect: lambda { |_url, &blk|
      blk.call(conn)
      mode.stop
    })
    mode.run
    assert_equal [{ "envelope_id" => "E1" }], conn.sent
    assert_equal 1, @events.size
  end

  def test_run_reconnects_with_exponential_backoff_capped_at_30
    sleeps = []
    attempts = 0
    mode = build(sleeper: ->(secs) { sleeps << secs },
                 connect: lambda { |_url, &_blk|
                   attempts += 1
                   mode.stop if attempts >= 8
                   raise "down"
                 })
    mode.run
    assert_equal [1, 2, 4, 8, 16, 30, 30], sleeps
  end

  def test_backoff_base_is_injectable_and_resets_after_success
    sleeps = []
    attempts = 0
    mode = build(backoff_base: 0.01, sleeper: ->(secs) { sleeps << secs },
                 connect: lambda { |_url, &blk|
                   attempts += 1
                   raise "down" if [1, 2, 4].include?(attempts)
                   next mode.stop if attempts == 5

                   blk.call(FakeConnection.new([JSON.generate({ "type" => "hello" })]))
                 })
    mode.run
    assert_equal [0.01, 0.02, 0.01], sleeps.first(3)
  end

  def test_open_socket_connection_failure_backs_off
    sleeps = []
    slack = Object.new
    calls = 0
    mode = nil
    slack.define_singleton_method(:open_socket_connection) do
      calls += 1
      mode.stop if calls == 2
      raise "nope"
    end
    mode = build(slack: slack, sleeper: ->(secs) { sleeps << secs })
    mode.run
    assert_equal [1], sleeps
  end

  def test_on_connected_called_when_socket_is_up
    connected = 0
    mode = build(on_connected: -> { connected += 1 }, sleeper: ->(_secs) {},
                 connect: lambda { |_url, &blk|
                   blk.call(FakeConnection.new([nil]))
                   mode.stop
                 })
    mode.run
    assert_equal 1, connected
  end
end

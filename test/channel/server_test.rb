# frozen_string_literal: true

require "test_helper"

class ChannelServerTest < Minitest::Test
  Server = Conclave::Channel::Server

  class FakeHub
    attr_reader :calls

    def initialize(response: { "id" => 1, "ok" => true }, error: nil)
      @response = response
      @error = error
      @calls = []
    end

    def request(operation, **fields)
      @calls << [operation, fields]
      raise @error if @error

      @response
    end
  end

  DELIVERY = {
    "channel" => "dev", "channel_id" => "C1", "ts" => "1.1", "thread_ts" => nil, "sender" => "UTAD",
    "sender_role" => "owner", "authority" => "UTAD", "text" => "@tad_sc-1 hi", "shared" => []
  }.freeze

  def capture_notification(message)
    original = $stdout
    $stdout = StringIO.new
    transport = Conclave::Channel::SyncStdioTransport.new(Server.build(agent: "a", hub: FakeHub.new))
    Server.deliverer(transport).call(message)
    JSON.parse($stdout.string)
  ensure
    $stdout = original
  end

  def call_tool(hub, name, arguments)
    server = Server.build(agent: "tad_sc-1", hub: hub)
    server.handle({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } })
          .fetch(:result)
  end

  def test_delivery_becomes_channel_notification
    note = capture_notification(DELIVERY)

    assert_equal "notifications/claude/channel", note["method"]
    assert_equal "@tad_sc-1 hi", note.dig("params", "content")
    meta = note.dig("params", "meta")

    assert(meta.keys.all? { it.match?(/\A\w+\z/) })
    assert_equal "owner", meta["sender_role"]
    refute_includes meta.keys, "text"
    refute_includes meta.keys, "shared"
    refute_includes meta.keys, "thread_ts"
  end

  def test_meta_drops_unsafe_keys_and_stringifies_values
    meta = Server.notification_params(DELIVERY.merge("bad-key" => "x", "count" => 3))[:meta]

    refute_includes meta.keys, "bad-key"
    assert_equal "3", meta["count"]
  end

  def test_shared_items_rendered_in_content
    shared = [{ "author" => "UBOB", "ts" => "9.9", "text" => "linked words" }]
    note = capture_notification(DELIVERY.merge("shared" => shared))

    assert_equal "@tad_sc-1 hi\n\n[Shared by Tad — UBOB at 9.9]\nlinked words", note.dig("params", "content")
  end

  def test_deliverer_swallows_errors
    transport = Object.new
    def transport.send_notification(*) = raise("boom")

    assert_output(nil, /notification failed/) { Server.deliverer(transport).call(DELIVERY) }
  end

  def test_instructions_name_the_agent
    server = Server.build(agent: "tad_sc-1", hub: FakeHub.new)

    assert_includes server.instructions, 'as "tad_sc-1"'
    assert_includes server.instructions, 'Text marked "Shared by Tad" is context Tad approved'
  end

  def test_tools_return_error_when_hub_down
    hub = FakeHub.new(error: Conclave::Channel::HubUnavailable)
    result = call_tool(hub, "list_channels", {})

    assert result[:isError]
    assert_equal "Conclave hub not running", result[:content].first[:text]
  end

  def test_hub_refusal_becomes_error_with_hub_text
    hub = FakeHub.new(response: { "id" => 1, "ok" => false, "error" => "not a member of #x" })
    result = call_tool(hub, "list_agents", { channel: "#x" })

    assert result[:isError]
    assert_equal "not a member of #x", result[:content].first[:text]
  end

  def test_success_returns_json_text_without_envelope
    hub = FakeHub.new(response: { "id" => 1, "ok" => true, "ts" => "5.5" })
    result = call_tool(hub, "send_message", { channel: "dev", text: "hi", thread_ts: "1.1", in_reply_to_ts: "1.1" })

    refute result[:isError]
    assert_equal({ "ts" => "5.5" }, JSON.parse(result[:content].first[:text]))
    assert_equal [["send_message", { channel: "dev", text: "hi", thread_ts: "1.1", in_reply_to_ts: "1.1" }]], hub.calls
  end

  def test_agent_name_shortened
    assert_equal "tad_sc-1234", Server.agent_name({ "CONCLAVE_AGENT" => "tad_sc-1234-foo" })
    assert_equal "plain", Server.agent_name({ "CONCLAVE_AGENT" => "plain" })
    assert_nil Server.agent_name({})
  end

  def test_socket_path_uses_conclave_home
    assert_equal "/x/hub.sock", Server.socket_path({ "CONCLAVE_HOME" => "/x" })
    assert_equal File.join(Dir.home, ".conclave", "hub.sock"), Server.socket_path({})
  end
end

# frozen_string_literal: true

require "test_helper"
require "socket"

class HubConnectionTest < Minitest::Test
  Connection = Conclave::Channel::HubConnection
  A = "tad_sc-1234"

  def setup
    @dir = Dir.mktmpdir("cv")
    @path = File.join(@dir, "hub.sock")
    @delivered = Queue.new
    @cleanup = []
  end

  def teardown
    @cleanup.reverse_each(&:call)
    FileUtils.remove_entry(@dir)
  end

  def build_hub_server
    store = Conclave::Store.new(":memory:")
    authority = Conclave::Hub::Authority.new(owner: "UTAD", store: store)
    slack = Conclave::Slack::Client.new(token: "xoxb-test")
    agents = Conclave::Hub::Agents.new(store: store, authority: authority, slack: slack,
                                       loop_guard_limit: 10, queue_limit: 50)
    epics = Object.new
    def epics.ensure_joined(_agent) = nil
    handler = Conclave::Hub::Handler.new(agents: agents, store: store, slack: slack, authority: authority,
                                         epic_channels: epics, bot_id: "BHUB", lock: Mutex.new)
    store.add_membership(A, "C1")
    Conclave::Hub::Server.new(path: @path, handler: handler)
  end

  def connect(agent: A, **)
    conn = Connection.new(path: @path, agent: agent, on_deliver: ->(m) { @delivered << m }, base_delay: 0.05,
                          **)
    @cleanup << conn.method(:stop)
    conn.start
  end

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    assert yield
  end

  # A scripted fake hub: the block receives each accepted socket.
  def fake_hub(&)
    server = UNIXServer.new(@path)
    thread = Thread.new do
      loop { Thread.new(server.accept, &) }
    rescue IOError, SystemCallError
      nil
    end
    @cleanup << lambda {
      server.close
      thread.kill
    }
    server
  end

  def test_request_raises_while_disconnected
    conn = Connection.new(path: @path, agent: A, on_deliver: ->(_) {})

    assert_raises(Conclave::Channel::HubUnavailable) { conn.request(:list_channels) }
  end

  def test_registers_and_requests
    server = build_hub_server.start
    @cleanup << server.method(:stop)
    conn = connect
    wait_until { conn.registered? }

    assert_equal [{ "name" => A, "online" => true }], conn.request(:list_agents, channel: "C1")["agents"]
  end

  def test_reconnects_after_hub_restart
    server = build_hub_server.start
    conn = connect
    wait_until { conn.registered? }
    server.stop
    wait_until { !conn.registered? }
    assert_raises(Conclave::Channel::HubUnavailable) { conn.request(:list_channels) }

    server = build_hub_server.start
    @cleanup << server.method(:stop)
    wait_until { conn.registered? }

    assert_equal [{ "name" => A, "online" => true }], conn.request(:list_agents, channel: "C1")["agents"]
  end

  def test_agent_name_shortened
    server = build_hub_server.start
    @cleanup << server.method(:stop)
    conn = connect(agent: Conclave::Channel::Server.agent_name({ "CONCLAVE_AGENT" => "tad_sc-1234-foo" }))
    wait_until { conn.registered? }

    assert_equal A, conn.agent
    assert_equal [{ "name" => A, "online" => true }], conn.request(:list_agents, channel: "C1")["agents"]
  end

  def test_deliver_before_register_response_reaches_on_deliver
    fake_hub do |sock|
      request = Conclave::Protocol.read(sock)
      Conclave::Protocol.write(sock, { op: "deliver", message: { text: "early" } })
      Conclave::Protocol.write(sock, { id: request["id"], ok: true })
      sleep
    end
    conn = connect

    assert_equal({ "text" => "early" }, Timeout.timeout(3) { @delivered.pop })
    wait_until { conn.registered? }
  end

  def test_pending_requests_fail_on_disconnect
    fake_hub do |sock|
      register = Conclave::Protocol.read(sock)
      Conclave::Protocol.write(sock, { id: register["id"], ok: true })
      Conclave::Protocol.read(sock)
      sock.close
    end
    conn = connect(request_timeout: 5)
    wait_until { conn.registered? }
    started = Time.now

    assert_raises(Conclave::Channel::HubUnavailable) { conn.request(:list_channels) }
    assert_operator Time.now - started, :<, 2
  end

  def test_request_times_out
    fake_hub do |sock|
      register = Conclave::Protocol.read(sock)
      Conclave::Protocol.write(sock, { id: register["id"], ok: true })
      sleep
    end
    conn = connect(request_timeout: 0.2)
    wait_until { conn.registered? }

    assert_raises(Conclave::Channel::RequestTimeout) { conn.request(:list_channels) }
  end

  def test_name_taken_is_logged_and_retried
    attempts = Queue.new
    fake_hub do |sock|
      register = Conclave::Protocol.read(sock)
      attempts << Time.now
      Conclave::Protocol.write(sock, { id: register["id"], ok: false, error: "name_taken" })
    end
    conn = nil
    _, err = capture_io do
      conn = connect
      wait_until { attempts.size >= 3 }
    end

    refute_predicate conn, :registered?
    assert_match(/name_taken/, err)
  end

  def test_on_deliver_errors_do_not_kill_reader
    fake_hub do |sock|
      register = Conclave::Protocol.read(sock)
      Conclave::Protocol.write(sock, { id: register["id"], ok: true })
      Conclave::Protocol.write(sock, { op: "deliver", message: { text: "boom" } })
      Conclave::Protocol.write(sock, { op: "deliver", message: { text: "fine" } })
      sleep
    end
    seen = Queue.new
    conn = Connection.new(path: @path, agent: A, base_delay: 0.05,
                          on_deliver: ->(m) { m["text"] == "boom" ? raise("x") : seen << m })
    @cleanup << conn.method(:stop)
    capture_io do
      conn.start
      assert_equal({ "text" => "fine" }, Timeout.timeout(3) { seen.pop })
    end
  end

  def test_request_pins_op_and_id_over_caller_fields
    seen = Queue.new
    fake_hub do |sock|
      register = Conclave::Protocol.read(sock)
      Conclave::Protocol.write(sock, { id: register["id"], ok: true })
      request = Conclave::Protocol.read(sock)
      seen << request
      Conclave::Protocol.write(sock, { id: request["id"], ok: true })
      sleep
    end
    conn = connect
    wait_until { conn.registered? }
    conn.request(:list_channels, op: "forget", id: 999, agent: "x")
    sent = Timeout.timeout(3) { seen.pop }

    assert_equal "list_channels", sent["op"]
    refute_equal 999, sent["id"]
    assert_equal "x", sent["agent"]
  end

  def test_non_object_line_does_not_stop_reconnects
    connections = Queue.new
    fake_hub do |sock|
      register = Conclave::Protocol.read(sock)
      connections << true
      Conclave::Protocol.write(sock, { id: register["id"], ok: true })
      sock.write("[1]\n")
      Conclave::Protocol.write(sock, { op: "deliver", message: { text: "later" } })
      sleep 0.1
      sock.close
    end
    capture_io do
      connect
      assert_equal({ "text" => "later" }, Timeout.timeout(3) { @delivered.pop })
      2.times { Timeout.timeout(3) { connections.pop } }
    end
  end

  def test_unexpected_session_error_falls_through_to_reconnect
    server = build_hub_server.start
    @cleanup << server.method(:stop)
    calls = 0
    original = UNIXSocket.method(:new)
    UNIXSocket.define_singleton_method(:new) do |*args|
      calls += 1
      raise ArgumentError, "too long unix socket path" if calls == 1

      original.call(*args)
    end
    @cleanup << -> { UNIXSocket.singleton_class.remove_method(:new) }
    capture_io do
      conn = connect
      wait_until { conn.registered? }
    end

    assert_operator calls, :>=, 2
  end

  def test_stale_socket_cannot_mark_registered
    conn = Connection.new(path: @path, agent: A, on_deliver: ->(_) {})
    conn.send(:mark_registered, Object.new)

    refute_predicate conn, :registered?
  end

  def test_hub_down_at_start_keeps_retrying
    conn = nil
    capture_io do
      conn = connect
      sleep 0.2
    end
    server = build_hub_server.start
    @cleanup << server.method(:stop)
    wait_until { conn.registered? }
  end
end

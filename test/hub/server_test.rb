# frozen_string_literal: true

require "test_helper"
require "socket"

class ServerTest < Minitest::Test
  A = "tad_sc-1234"
  CH = "C1"

  def setup
    @dir = Dir.mktmpdir("cv")
    @path = File.join(@dir, "hub.sock")
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @agents = Conclave::Hub::Agents.new(store: @store, authority: @authority, slack: @slack,
                                        loop_guard_limit: 10, queue_limit: 50)
    epics = Object.new
    def epics.ensure_joined(_agent) = nil
    @handler = Conclave::Hub::Handler.new(agents: @agents, store: @store, slack: @slack, authority: @authority,
                                          epic_channels: epics, bot_id: "BHUB", lock: Mutex.new)
    @store.add_membership(A, CH)
    @server = Conclave::Hub::Server.new(path: @path, handler: @handler)
    @sockets = []
  end

  def teardown
    @sockets.each { |s| s.close unless s.closed? }
    @server.stop
    FileUtils.remove_entry(@dir)
  end

  def connect
    UNIXSocket.new(@path).tap { |s| @sockets << s }
  end

  def rpc(sock, hash)
    Conclave::Protocol.write(sock, hash)
    Conclave::Protocol.read(sock)
  end

  def wait_until(timeout = 2)
    deadline = Time.now + timeout
    sleep 0.01 until yield || Time.now > deadline
    assert yield
  end

  def test_socket_round_trip
    @server.start
    sock = connect
    assert_equal({ "id" => 1, "ok" => true }, rpc(sock, { id: 1, op: "register", agent: A }))
    response = rpc(sock, { id: 2, op: "list_agents", channel: CH })
    assert_equal [{ "name" => A, "online" => true }], response["agents"]
  end

  def test_socket_file_is_0600
    @server.start
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert File.socket?(@path)
  end

  def test_creates_missing_parent_dir_0700
    nested = File.join(@dir, "sub")
    server = Conclave::Hub::Server.new(path: File.join(nested, "h.sock"), handler: @handler)
    server.start
    assert_equal 0o700, File.stat(nested).mode & 0o777
  ensure
    server&.stop
  end

  def test_removes_stale_socket_file
    UNIXServer.new(@path).close
    assert File.socket?(@path)
    @server.start
    assert_equal true, rpc(connect, { id: 1, op: "register", agent: A })["ok"]
  end

  def test_does_not_remove_regular_file
    File.write(@path, "precious")
    assert_raises(SystemCallError) { @server.start }
    assert_equal "precious", File.read(@path)
  end

  def test_deliver_pushes_message_to_registered_connection
    @server.start
    sock = connect
    rpc(sock, { id: 1, op: "register", agent: A })
    @agents.deliver(A, { channel_id: CH, ts: "1.1", authority: "UTAD", text: "hello" })
    push = Conclave::Protocol.read(sock)
    assert_equal "deliver", push["op"]
    assert_equal "hello", push["message"]["text"]
  end

  def test_register_name_taken_does_not_crash_server
    @server.start
    first = connect
    rpc(first, { id: 1, op: "register", agent: A })
    second = connect
    assert_equal "name_taken", rpc(second, { id: 1, op: "register", agent: A })["error"]
    assert_equal true, rpc(second, { id: 2, op: "forget", agent: "nobody" })["ok"]
  end

  def test_malformed_line_and_unknown_op_keep_connection_open
    @server.start
    sock = connect
    sock.write("{not json\n")
    assert_equal({ "ok" => false, "error" => "bad request" }, Conclave::Protocol.read(sock))
    assert_equal({ "id" => 5, "ok" => false, "error" => "bad request" }, rpc(sock, { id: 5, op: "bogus" }))
    assert_equal true, rpc(sock, { id: 6, op: "register", agent: A })["ok"]
  end

  def test_disconnect_unregisters_agent
    @server.start
    sock = connect
    rpc(sock, { id: 1, op: "register", agent: A })
    assert @agents.online?(A)
    sock.close
    wait_until { !@agents.online?(A) }
  end

  def test_stop_removes_socket_file
    @server.start
    @server.stop
    refute File.exist?(@path)
  end
end

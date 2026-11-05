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
    @lock = Mutex.new
    @handler = Conclave::Hub::Handler.new(agents: @agents, store: @store, slack: @slack, authority: @authority,
                                          epic_channels: epics, bot_id: "BHUB", lock: @lock)
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

  def test_slow_client_does_not_block_other_clients
    @store.add_membership("tad_sc-2", CH)
    @server.start
    slow = connect
    rpc(slow, { id: 1, op: "register", agent: A })
    other = connect
    rpc(other, { id: 1, op: "register", agent: "tad_sc-2" })
    stub_slack(:post, "reactions.add")
    big = "x" * 20_000
    Timeout.timeout(5) do
      @lock.synchronize do
        2500.times { |i| @agents.deliver(A, { channel_id: CH, ts: "1.#{i}", authority: "UTAD", text: big }) }
      end
    end
    started = Time.now
    assert_equal true, rpc(other, { id: 2, op: "list_agents", channel: CH })["ok"]
    assert_operator Time.now - started, :<, 2
    wait_until { !@agents.online?(A) } # outbox overflow closed the slow connection via disconnected
  end

  def test_failed_write_disconnects_agent
    @server.start
    sock = connect
    rpc(sock, { id: 1, op: "register", agent: A })
    sock.close
    wait_until { !@agents.online?(A) }
    assert_equal true, rpc(connect, { id: 1, op: "register", agent: A })["ok"]
  end

  def test_overflowed_connection_falls_back_to_offline_queue
    @server.start
    sock = connect
    rpc(sock, { id: 1, op: "register", agent: A })
    stub_slack(:post, "reactions.add")
    big = "x" * 20_000
    @lock.synchronize do
      2500.times { |i| @agents.deliver(A, { channel_id: CH, ts: "1.#{i}", authority: "UTAD", text: big }) }
    end
    refute @agents.online?(A)
    assert_operator @store.drain(A).size, :>, 0
    assert_requested(:post, /reactions\.add/, at_least_times: 1)
  end

  def test_socket_write_error_closes_connection_and_unregisters_agent
    socket = Object.new
    def socket.write(*) = raise(Errno::EPIPE)
    def socket.closed? = false
    def socket.shutdown(*) = nil
    def socket.close = nil
    connection = Conclave::Hub::Server::Connection.new(socket)
    @agents.register(A, connection)
    @handler.instance_variable_get(:@registered)[connection] = A
    connection.write({ id: 1, ok: true })
    wait_until { connection.closed? }
    @handler.disconnected(connection)
    refute @agents.online?(A)
    assert_equal false, connection.write({ id: 2 })
  end

  def test_unserializable_response_gets_fallback_error
    handler = Object.new
    handler.define_singleton_method(:call) { |_req, _conn| { id: 7, ok: true, bad: "\xFF".b.force_encoding("UTF-8") } }
    handler.define_singleton_method(:disconnected) { |_conn| nil }
    server = Conclave::Hub::Server.new(path: File.join(@dir, "f.sock"), handler: handler).start
    sock = UNIXSocket.new(File.join(@dir, "f.sock")).tap { |s| @sockets << s }
    response = rpc(sock, { id: 7, op: "list_agents" })
    assert_equal({ "id" => 7, "ok" => false, "error" => "internal error" }, response)
  ensure
    server&.stop
  end

  def test_accept_error_does_not_end_accept_loop
    flaky = Class.new(Conclave::Hub::Server) do
      private

      def listen
        super.tap do |server|
          failed = false
          server.define_singleton_method(:accept) do
            unless failed
              failed = true
              raise Errno::EMFILE
            end
            super()
          end
        end
      end
    end.new(path: @path, handler: @handler)
    capture_io do
      flaky.start
      assert_equal true, rpc(connect, { id: 1, op: "register", agent: A })["ok"]
    end
  ensure
    flaky&.stop
  end

  def test_invalid_utf8_and_bad_id_get_bad_request
    @server.start
    sock = connect
    sock.write("{\"id\":1,\"op\":\"register\",\"agent\":\"\xFF\"}\n".b)
    assert_equal "bad request", Conclave::Protocol.read(sock)["error"]
    assert_equal "bad request", rpc(sock, { id: 1.5, op: "register", agent: A })["error"]
    assert_equal "bad request", rpc(sock, { id: { a: 1 }, op: "register", agent: A })["error"]
    assert_equal true, rpc(sock, { id: 2, op: "register", agent: A })["ok"]
  end

  def test_oversized_line_gets_bad_request_and_closes
    @server.start
    sock = connect
    sock.write("#{'a' * (Conclave::Protocol::MAX_LINE + 10)}\n")
    assert_equal "bad request", Conclave::Protocol.read(sock)["error"]
    assert_nil Conclave::Protocol.read(sock)
  end

  def test_stop_removes_socket_file
    @server.start
    @server.stop
    refute File.exist?(@path)
  end
end

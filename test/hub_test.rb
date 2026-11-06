# frozen_string_literal: true

require "test_helper"
require "socket"
require "timeout"

class HubTest < Minitest::Test
  AGENT = "tad_sc-1234"
  CH = "C1"

  class FakeConnection
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def closed? = false

    def deliver(message) # rubocop:disable Naming/PredicateMethod
      @deliveries << message
      true
    end
  end

  def setup
    @dir = Dir.mktmpdir("cvhub")
    @config = Conclave::Config.new({ "bot_token" => "xoxb-1", "app_token" => "xapp-1", "owner_user_id" => "UTAD",
                                     "shortcut_token" => "sc-token" }, home: @dir)
    stub_slack(:post, "auth.test", response_body: { "bot_id" => "BHUB", "user" => "conclave" })
  end

  def teardown
    @thread&.kill
    @thread&.join(2)
    @hub&.shutdown
    FileUtils.remove_entry(@dir)
    super # WebMock's request reset lives in Minitest::Test#teardown; skipping it leaks request counts
  end

  def hub
    @hub ||= Conclave::Hub.new(config: @config)
  end

  def test_construction_takes_bot_id_from_auth_test_and_builds_components
    assert_instance_of Conclave::Hub::Router, hub.router
    assert_instance_of Conclave::Store, hub.store
    assert_requested :post, "#{SLACK_BASE_URL}/auth.test", times: 1
    assert File.exist?(@config.db_path)
  end

  def test_hub_slack_client_does_not_sleep_on_rate_limit
    stub = stub_request(:post, "#{SLACK_BASE_URL}/auth.test").to_return(status: 429, body: "")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Conclave::Slack::Client::RateLimitError) { hub }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
    assert_requested stub, times: 1
  end

  def test_blank_credentials_fail_fast_with_clear_message
    %w[bot_token app_token owner_user_id shortcut_token].each do |key|
      values = { "bot_token" => "a", "app_token" => "b", "owner_user_id" => "c", "shortcut_token" => "d", key => " " }
      error = assert_raises(Conclave::Hub::ConfigError) do
        Conclave::Hub.new(config: Conclave::Config.new(values, home: @dir))
      end
      assert_includes error.message, key
    end
  end

  def test_synchronize_uses_the_hub_lock
    result = hub.synchronize { :inside }
    assert_equal :inside, result
    assert_raises(ThreadError) { hub.synchronize { hub.synchronize { nil } } }
  end

  def test_live_hub_probe_refuses_when_something_answers
    server = UNIXServer.new(@config.socket_path)
    error = assert_raises(Conclave::Hub::AlreadyRunning) { hub.ensure_not_running! }
    assert_equal "hub already running at #{@config.socket_path}", error.message
  ensure
    server&.close
  end

  def test_live_hub_probe_passes_when_socket_missing_or_stale
    hub.ensure_not_running!
    UNIXServer.new(@config.socket_path).close
    hub.ensure_not_running!
  end

  def register_agent
    stub_slack(:get, "conversations.info", query: hash_including("channel" => CH), response_body: { "channel" => { "name" => "general" } })
    connection = FakeConnection.new
    hub.store.add_membership(AGENT, CH)
    hub.agents.register(AGENT, connection)
    connection
  end

  def slack_message(user, text, ts)
    { "type" => "message", "user" => user, "text" => text, "ts" => ts, "channel" => CH }
  end

  def test_backfill_routes_missed_messages_through_rules
    connection = register_agent
    hub.store.set_last_seen(CH, "1700000000.000100")
    history = stub_slack(:get, "conversations.history",
                         query: hash_including("channel" => CH, "oldest" => "1700000000.000100", "limit" => "200"),
                         response_body: { "messages" => [
                           slack_message("UOUT", "#{AGENT}: hi", "1700000003.000100"),
                           slack_message("UTAD", "#{AGENT}: please look", "1700000002.000100"),
                           slack_message("UTAD", "#{AGENT}: already seen", "1700000000.000100")
                         ].map { |m| m.except("channel") } })
    hub.backfill
    assert_requested history
    texts = connection.deliveries.map { |d| d[:text] }
    assert_equal 1, texts.size
    assert_match(/please look/, texts.first)
    assert_equal "1700000003.000100", hub.store.last_seen(CH)
  end

  def test_backfill_continues_after_a_channel_fails
    connection = register_agent
    hub.store.set_last_seen("C0", "1700000000.000100")
    hub.store.set_last_seen(CH, "1700000000.000100")
    stub_slack(:get, "conversations.history", query: hash_including("channel" => "C0"),
                                              status: 500, response_body: {})
    stub_slack(:get, "conversations.history", query: hash_including("channel" => CH),
                                              response_body: { "messages" => [
                                                slack_message("UTAD", "#{AGENT}: go", "1700000002.000100")
                                              ] })
    _out, err = capture_io { hub.backfill }
    assert_match(/backfill C0/, err)
    assert_equal 1, connection.deliveries.size
  end

  def test_run_serves_the_socket_and_stops_cleanly_on_term
    stub_slack(:post, "apps.connections.open", status: 500)
    capture_io do
      @thread = Thread.new { hub.run }
      Timeout.timeout(5) { sleep 0.05 until File.socket?(@config.socket_path) }
      Process.kill("TERM", Process.pid)
      assert @thread.join(5), "hub.run did not return after TERM"
    end
    refute File.exist?(@config.socket_path)
    assert_raises(ArgumentError) { hub.store.last_seen("C1") } # store closed
  end

  def test_run_exits_with_a_clear_error_when_slack_rejects_the_app_token
    stub_slack(:post, "apps.connections.open", status: 401)
    error = nil
    capture_io do
      thread = Thread.new { hub.run }
      error = assert_raises(Conclave::Hub::AppTokenRejected) { Timeout.timeout(5) { thread.value } }
    end
    assert_match(/\ASlack app token rejected: .*authentication/i, error.message)
    refute File.exist?(@config.socket_path)
  end

  def test_forget_remote_reports_when_hub_is_down
    line = Conclave::Hub.forget_remote("x", path: File.join(@dir, "nope.sock"))
    assert_match(/not running/, line)
  end

  def test_forget_remote_sends_forget_and_reports_result
    path = File.join(@dir, "f.sock")
    server = UNIXServer.new(path)
    received = nil
    thread = Thread.new do
      client = server.accept
      received = Conclave::Protocol.read(client)
      Conclave::Protocol.write(client, { id: 1, ok: false, error: "agent online" })
      client.close
    end
    line = Conclave::Hub.forget_remote("tad_sc-1", path: path)
    thread.join
    assert_equal({ "id" => 1, "op" => "forget", "agent" => "tad_sc-1" }, received)
    assert_match(/agent online/, line)
  ensure
    server&.close
  end
end

# frozen_string_literal: true

require "test_helper"

class NoticesTest < Minitest::Test
  A = "tad_sc-1234"
  B = "tad_sc-5678"
  CH = "C1"
  ADDED = "tad_sc-1234, tad_sc-5678: Tad added you to #billing-rework."

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
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @agents = Conclave::Hub::Agents.new(store: @store, authority: @authority, slack: @slack,
                                        loop_guard_limit: 10, queue_limit: 50)
    @notices = Conclave::Hub::Notices.new(agents: @agents, slack: @slack, store: @store, owner: "UTAD")
    @store.add_membership(A, CH)
    @store.add_membership(B, CH)
    stub_slack(:get, "conversations.info", query: { channel: CH },
                                           response_body: { "channel" => { "name" => "billing-rework" } })
    @post = stub_slack(:post, "chat.postMessage", response_body: { "ts" => "7.7" })
    stub_slack(:post, "reactions.add")
    @conn_a = FakeConnection.new
    @conn_b = FakeConnection.new
  end

  def test_added_posts_as_the_bot_and_delivers_to_each_agent
    @agents.register(A, @conn_a)
    @agents.register(B, @conn_b)
    @notices.added([A, B], CH)
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      body = JSON.parse(req.body)
      body["username"] == "conclave" && body["channel"] == CH && body["text"] == ADDED && !body.key?("thread_ts")
    end
    [@conn_a, @conn_b].each do |conn|
      assert_equal [{ channel: "billing-rework", channel_id: CH, ts: "7.7", thread_ts: nil, sender: "conclave",
                      sender_role: "conclave", authority: "UTAD", text: ADDED, shared: [] }], conn.deliveries
    end
  end

  CONSULTED = "tad_sc-1234: Tad lets you consult Fifty (Slack user UFIFTY). Mention it to ask; its replies in your " \
              "threads reach you."

  def test_consulted_names_the_bot_without_mentioning_it
    @agents.register(A, @conn_a)
    @notices.consulted(A, "Fifty", "UFIFTY", CH)
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      body = JSON.parse(req.body)
      body["username"] == "conclave" && body["channel"] == CH && body["text"] == CONSULTED
    end
    refute_includes CONSULTED, "<@"
    assert_equal([["conclave", "UTAD", CONSULTED]], @conn_a.deliveries.map { |m| m.values_at(:sender_role, :authority, :text) })
  end

  def test_unconsulted_falls_back_to_the_id_without_a_name
    @agents.register(A, @conn_a)
    @notices.unconsulted(A, nil, "UFIFTY", CH)
    assert_equal(["tad_sc-1234: Tad stopped your consult of Slack user UFIFTY. Its messages no longer reach you."],
                 @conn_a.deliveries.map { |m| m[:text] })
  end

  def test_notice_is_recorded_with_owner_authority
    @notices.added([A], CH)
    assert_equal "UTAD", @store.post_authority(CH, "7.7")
  end

  def test_joined_common_wording
    @agents.register(A, @conn_a)
    @notices.joined_common(A, CH)
    assert_equal(["tad_sc-1234: you joined #billing-rework, the common channel."],
                 @conn_a.deliveries.map { |m| m[:text] })
  end

  def test_offline_agent_gets_the_notice_queued_with_zzz
    reaction = stub_slack(:post, "reactions.add",
                          request_body: hash_including("channel" => CH, "timestamp" => "7.7", "name" => "zzz"))
    @notices.added([A], CH)
    assert_requested reaction
    assert_equal(["tad_sc-1234: Tad added you to #billing-rework."], @store.drain(A).map { |p| p["text"] })
  end

  # A's window is closed by its post and narrowed to Jane. A notice must not widen it back to Tad, which it
  # would if it were delivered as sender_role "owner".
  def test_notice_does_not_widen_a_closed_window
    @store.authorize(A, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, { channel: "x", channel_id: CH, ts: "1", thread_ts: nil, sender: "UJANE",
                         sender_role: "authorized", authority: "UJANE", text: "hi", shared: [] })
    @agents.post(agent: A, channel_id: CH, text: "on it")
    @notices.added([A], CH)
    @agents.post(agent: A, channel_id: CH, text: "#{B}: delete it")
    assert_empty @conn_b.deliveries
  end

  # A notice carries the owner's authority, which is neutral: it must not narrow the window either.
  def test_notice_does_not_narrow_the_window
    @agents.register(B, @conn_b)
    @notices.added([A], CH)
    @agents.post(agent: A, channel_id: CH, text: "#{B}: go")
    assert_equal(["UTAD"], @conn_b.deliveries.map { |m| m[:authority] })
  end

  def test_failed_post_is_reported_and_delivers_nothing
    stub_slack(:post, "chat.postMessage", response_body: { "ok" => false, "error" => "boom" })
    @agents.register(A, @conn_a)
    _, err = capture_io { @notices.added([A], CH) }
    assert_match(/notice failed.*boom/, err)
    assert_empty @conn_a.deliveries
  end
end

# frozen_string_literal: true

require "test_helper"

class AgentsTest < Minitest::Test
  A = "tad_sc-1234"
  B = "tad_sc-5678"
  CH = "C1"

  class FakeConnection
    attr_reader :deliveries

    def initialize
      @deliveries = []
      @closed = false
    end

    def closed? = @closed

    def close! = @closed = true

    def deliver(message) # rubocop:disable Naming/PredicateMethod
      @deliveries << message
      true
    end
  end

  def setup
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @agents = build_agents(limit: 10)
    @store.add_membership(A, CH)
    @store.add_membership(B, CH)
    @post_stub = stub_slack(:post, "chat.postMessage", response_body: { "ts" => "100.1" })
    stub_slack(:get, "conversations.info", query: { channel: CH }, response_body: { "channel" => { "name" => "epic-1-x" } })
    stub_slack(:post, "reactions.add")
    @conn_a = FakeConnection.new
    @conn_b = FakeConnection.new
  end

  def build_agents(limit:)
    Conclave::Hub::Agents.new(store: @store, authority: @authority, slack: @slack,
                              loop_guard_limit: limit, queue_limit: 50)
  end

  def delivery(overrides = {})
    { channel: "epic-1-x", channel_id: CH, ts: "1", thread_ts: nil, sender: "UTAD", sender_role: "owner",
      authority: "UTAD", text: "hi", shared: [] }.merge(overrides)
  end

  def posted_bodies
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys
                            .select { |sig| sig.uri.path.end_with?("chat.postMessage") }
                            .map { |sig| JSON.parse(sig.body) }
  end

  def test_authority_exposes_owner
    assert_equal "UTAD", @authority.owner
  end

  def test_register_rejects_duplicate_online_name
    assert_equal :ok, @agents.register(A, @conn_a)
    assert_equal :name_taken, @agents.register(A, FakeConnection.new)
    assert @agents.online?(A)
    @agents.unregister(A)
    refute @agents.online?(A)
  end

  def test_online_delivery_goes_to_connection
    @agents.register(A, @conn_a)
    @agents.deliver(A, delivery)
    assert_equal(["hi"], @conn_a.deliveries.map { |m| m[:text] })
  end

  def test_offline_delivery_queues_and_reacts
    reaction = stub_slack(:post, "reactions.add",
                          request_body: hash_including("channel" => CH, "timestamp" => "1", "name" => "zzz"))
    @agents.deliver(A, delivery)
    assert_requested reaction

    @agents.register(A, @conn_a)
    assert_equal 1, @conn_a.deliveries.size
    assert_equal "hi", @conn_a.deliveries.first[:text]
    assert_equal CH, @conn_a.deliveries.first[:channel_id]
    assert_equal [], @store.drain(A)
  end

  def test_offline_delivery_survives_reaction_failure
    stub_slack(:post, "reactions.add", response_body: { "ok" => false, "error" => "already_reacted" })
    _, err = capture_io { @agents.deliver(A, delivery) }
    assert_match(/already_reacted/, err)
    @agents.register(A, @conn_a)
    assert_equal 1, @conn_a.deliveries.size
  end

  def test_drained_none_authority_is_restored
    @store.enqueue(A, delivery(authority: :none), limit: 50)
    @agents.register(A, @conn_a)
    assert_equal :none, @conn_a.deliveries.first[:authority]
  end

  def test_post_uses_agent_persona
    @agents.post(agent: A, channel_id: CH, text: "hello")
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      body = JSON.parse(req.body)
      body["username"] == A && body["icon_emoji"].is_a?(String) && body["channel"] == CH
    end
  end

  def test_post_returns_ts
    assert_equal({ ts: "100.1" }, @agents.post(agent: A, channel_id: CH, text: "hello"))
  end

  def test_post_delivers_to_addressed_peer
    @agents.register(B, @conn_b)
    @agents.post(agent: A, channel_id: CH, text: "@#{B} take a look", thread_ts: "50.0")
    delivered = @conn_b.deliveries.first
    assert_equal A, delivered[:sender]
    assert_equal "agent", delivered[:sender_role]
    assert_equal "UTAD", delivered[:authority]
    assert_equal "100.1", delivered[:ts]
    assert_equal "50.0", delivered[:thread_ts]
    assert_equal "epic-1-x", delivered[:channel]
    assert_equal CH, delivered[:channel_id]
    assert_equal [], delivered[:shared]
  end

  def test_post_does_not_deliver_to_self_or_unaddressed
    @agents.register(A, @conn_a)
    @agents.register(B, @conn_b)
    @agents.post(agent: A, channel_id: CH, text: "@#{A} @#{B}")
    assert_empty @conn_a.deliveries
    @agents.post(agent: A, channel_id: CH, text: "no mention")
    assert_equal 1, @conn_b.deliveries.size
  end

  def test_post_all_addresses_other_members
    @agents.register(B, @conn_b)
    @agents.register(A, @conn_a)
    @agents.post(agent: A, channel_id: CH, text: "@all heads up")
    assert_equal 1, @conn_b.deliveries.size
    assert_empty @conn_a.deliveries
  end

  def test_channel_name_falls_back_to_id_on_slack_error
    stub_slack(:get, "conversations.info", query: { channel: "C9" }, response_body: { "ok" => false, "error" => "boom" })
    @store.add_membership(B, "C9")
    @agents.register(B, @conn_b)
    @agents.post(agent: A, channel_id: "C9", text: "@#{B} hi")
    assert_equal "C9", @conn_b.deliveries.first[:channel]
  end

  def test_relayed_request_does_not_reach_unauthorized_agent
    @store.authorize(A, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(authority: "UJANE", sender: "UJANE", sender_role: "authorized"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} delete it")
    assert_empty @conn_b.deliveries
    assert_requested @post_stub
  end

  def test_authorized_authority_reaches_peer_authorized_for_same_user
    @store.authorize(A, "UJANE")
    @store.authorize(B, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(authority: "UJANE"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go")
    assert_equal "UJANE", @conn_b.deliveries.first[:authority]
  end

  def test_no_prior_delivery_uses_owner_authority
    @agents.register(B, @conn_b)
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go")
    assert_equal "UTAD", @conn_b.deliveries.first[:authority]
  end

  def test_none_authority_reaches_nobody
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(authority: :none))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go")
    assert_empty @conn_b.deliveries
  end

  def test_cannot_raise_authority_via_in_reply_to
    @store.authorize(A, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(ts: "1", authority: "UTAD"))
    @agents.deliver(A, delivery(ts: "2", authority: "UJANE", sender: "UJANE"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go", in_reply_to_ts: "1")
    assert_empty @conn_b.deliveries
  end

  def test_restart_keeps_delivered_authority
    @store.authorize(A, "UJANE")
    @agents.deliver(A, delivery(authority: "UJANE", sender: "UJANE", sender_role: "authorized"))
    restarted = build_agents(limit: 10)
    restarted.register(B, @conn_b)
    restarted.post(agent: A, channel_id: CH, text: "@#{B} delete it")
    assert_empty @conn_b.deliveries
    assert_requested @post_stub
  end

  def test_restart_without_history_defaults_to_owner
    restarted = build_agents(limit: 10)
    restarted.register(B, @conn_b)
    restarted.post(agent: A, channel_id: CH, text: "@#{B} go")
    assert_equal "UTAD", @conn_b.deliveries.first[:authority]
  end

  def test_later_owner_delivery_does_not_launder_earlier_authority
    @store.authorize(A, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(ts: "1", authority: "UJANE", sender: "UJANE", sender_role: "authorized"))
    @agents.deliver(A, delivery(ts: "2", authority: "UTAD"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} delete it")
    assert_empty @conn_b.deliveries
  end

  def test_window_resets_after_post
    @store.authorize(A, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(ts: "1", authority: "UJANE", sender: "UJANE", sender_role: "authorized"))
    @agents.deliver(A, delivery(ts: "2", authority: "UTAD"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} delete it")
    @agents.deliver(A, delivery(ts: "3", authority: "UTAD"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go")
    assert_equal(["UTAD"], @conn_b.deliveries.map { |m| m[:authority] })
  end

  def test_post_without_new_deliveries_keeps_last_post_authority
    @store.authorize(A, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(authority: "UJANE", sender: "UJANE", sender_role: "authorized"))
    @agents.post(agent: A, channel_id: CH, text: "status")
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go")
    assert_empty @conn_b.deliveries
  end

  def test_restart_mid_window_fails_closed
    @store.authorize(A, "UJANE")
    @agents.deliver(A, delivery(ts: "1", authority: "UJANE", sender: "UJANE", sender_role: "authorized"))
    restarted = build_agents(limit: 10)
    restarted.register(B, @conn_b)
    restarted.deliver(A, delivery(ts: "2", authority: "UTAD"))
    restarted.post(agent: A, channel_id: CH, text: "@#{B} delete it")
    assert_empty @conn_b.deliveries
  end

  def test_loop_guard_pauses_after_limit
    agents = build_agents(limit: 2)
    agents.register(B, @conn_b)
    3.times { agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0") }
    assert_equal 2, @conn_b.deliveries.size
    notes = posted_bodies.select { |b| b["username"] == "conclave" }
    assert_equal 1, notes.size
    assert_equal "50.0", notes.first["thread_ts"]
    assert_equal "Pausing agent-to-agent messages in this thread after 2 exchanges. @tad, reply here to continue.",
                 notes.first["text"]
    agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0")
    assert_equal(1, posted_bodies.count { |b| b["username"] == "conclave" })
  end

  def test_loop_guard_keys_top_level_posts_by_posted_ts
    agents = build_agents(limit: 1)
    agents.register(B, @conn_b)
    2.times { agents.post(agent: A, channel_id: CH, text: "@#{B} ping") }
    assert_equal 1, @conn_b.deliveries.size
    assert_equal "100.1", posted_bodies.find { |b| b["username"] == "conclave" }["thread_ts"]
  end

  def test_human_post_resets_loop_guard
    agents = build_agents(limit: 1)
    agents.register(B, @conn_b)
    2.times { agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0") }
    assert_equal 1, @conn_b.deliveries.size

    agents.human_posted(channel_id: CH, thread_key: "50.0", user_id: "UOUTSIDER")
    agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0")
    assert_equal 1, @conn_b.deliveries.size

    agents.human_posted(channel_id: CH, thread_key: "50.0", user_id: "UTAD")
    agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0")
    assert_equal 2, @conn_b.deliveries.size
  end

  def test_authorized_member_user_resets_loop_guard
    agents = build_agents(limit: 1)
    @store.authorize(B, "UJANE")
    agents.register(B, @conn_b)
    2.times { agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0") }
    agents.human_posted(channel_id: CH, thread_key: "50.0", user_id: "UJANE")
    agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0")
    assert_equal 2, @conn_b.deliveries.size
  end

  # B is authorized for Jane, so the window alone (Jane) would reach B: only the evicted reply target blocks it.
  def test_delivered_authority_is_bounded
    @store.authorize(A, "UJANE")
    @store.authorize(B, "UJANE")
    @agents.deliver(A, delivery(ts: "old", authority: "UJANE"))
    210.times { |i| @agents.deliver(A, delivery(ts: i.to_s, authority: "UTAD")) }
    @agents.register(B, @conn_b)
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go", in_reply_to_ts: "old")
    assert_empty @conn_b.deliveries
    assert_requested @post_stub
  end

  def test_unknown_in_reply_to_fails_closed
    @agents.register(B, @conn_b)
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go", in_reply_to_ts: "nope")
    assert_empty @conn_b.deliveries
    assert_requested @post_stub
  end

  def test_nil_authority_fails_closed
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(ts: "1", authority: "UTAD"))
    @agents.deliver(A, delivery(ts: "2", authority: nil))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go", in_reply_to_ts: "1")
    assert_empty @conn_b.deliveries
  end

  # Jane's message came before the last post, so the window is Tad's alone; in_reply_to brings Jane back in.
  def test_in_reply_to_lowers_authority
    @store.authorize(B, "UJANE")
    @agents.register(B, @conn_b)
    @agents.deliver(A, delivery(ts: "1", authority: "UJANE", sender: "UJANE"))
    @agents.post(agent: A, channel_id: CH, text: "on it")
    @agents.deliver(A, delivery(ts: "2", authority: "UTAD"))
    @agents.post(agent: A, channel_id: CH, text: "@#{B} go", in_reply_to_ts: "1")
    assert_equal "UJANE", @conn_b.deliveries.first[:authority]
  end

  def test_pause_note_failure_does_not_raise
    agents = build_agents(limit: 1)
    agents.register(B, @conn_b)
    stub_slack(:post, "chat.postMessage", request_body: hash_including("username" => "conclave"),
                                          response_body: { "ok" => false, "error" => "boom" })
    agents.post(agent: A, channel_id: CH, text: "@#{B} one", thread_ts: "50.0")
    _, err = capture_io { agents.post(agent: A, channel_id: CH, text: "@#{B} two", thread_ts: "50.0") }
    assert_match(/pause note failed.*boom/, err)
    assert_equal 1, @conn_b.deliveries.size
  end

  def test_closed_connection_falls_back_to_offline_queue
    @agents.register(A, @conn_a)
    @conn_a.close!
    @agents.deliver(A, delivery)
    refute @agents.online?(A)
    assert_empty @conn_a.deliveries
    assert_equal 1, @store.drain(A).size
    assert_requested(:post, /reactions\.add/)
  end

  def test_failed_delivery_falls_back_to_offline_queue
    conn = FakeConnection.new
    conn.define_singleton_method(:deliver) { |_message| false }
    @agents.register(A, conn)
    @agents.deliver(A, delivery)
    refute @agents.online?(A)
    assert_equal 1, @store.drain(A).size
    assert_requested(:post, /reactions\.add/)
  end

  def test_unregister_with_stale_connection_keeps_newer_registration
    @agents.register(A, @conn_a)
    @agents.unregister(A, @conn_b)
    assert @agents.online?(A)
    @agents.unregister(A, @conn_a)
    refute @agents.online?(A)
  end

  def test_pause_note_is_recorded_with_owner_authority
    agents = build_agents(limit: 1)
    agents.register(B, @conn_b)
    2.times { agents.post(agent: A, channel_id: CH, text: "@#{B} ping", thread_ts: "50.0") }
    assert_equal "UTAD", @store.post_authority(CH, "100.1")
  end
end

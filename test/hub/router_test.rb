# frozen_string_literal: true

require "test_helper"

class RouterTest < Minitest::Test
  A = "tad_sc-1234"
  B = "tad_sc-5678"
  CH = "C1"
  TS = "1700000000.000100"

  class FakeConnection
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver(message)
      @deliveries << message
    end
  end

  def setup
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @agents = Conclave::Hub::Agents.new(store: @store, authority: @authority, slack: @slack,
                                        loop_guard_limit: 10, queue_limit: 50)
    @commands = Conclave::Hub::Commands.new(store: @store, authority: @authority, slack: @slack, owner: "UTAD")
    @router = Conclave::Hub::Router.new(agents: @agents, authority: @authority, store: @store, slack: @slack,
                                        bot_id: "BHUB", commands: @commands)
    @store.add_membership(A, CH)
    @store.add_membership(B, CH)
    @conn_a = FakeConnection.new
    @conn_b = FakeConnection.new
    @agents.register(A, @conn_a)
    @agents.register(B, @conn_b)
    stub_slack(:get, "conversations.info", query: { channel: CH },
                                           response_body: { "channel" => { "name" => "epic-1-x" } })
    @post_stub = stub_slack(:post, "chat.postMessage", response_body: { "ts" => "9.9" })
    @reaction_stub = stub_slack(:post, "reactions.add")
  end

  def event(text, user: "UTAD", **extra)
    { "type" => "message", "user" => user, "text" => text, "channel" => CH, "ts" => TS }.merge(extra)
  end

  def test_ignores_own_bot_echo
    @router.handle_message(event("@#{A} hi", "bot_id" => "BHUB"))
    assert_empty @conn_a.deliveries
  end

  def test_ignores_subtype_and_missing_user
    @router.handle_message(event("@#{A} hi", "subtype" => "message_changed"))
    @router.handle_message(event("@#{A} hi").tap { |e| e.delete("user") })
    assert_empty @conn_a.deliveries
    assert_nil @store.last_seen(CH)
  end

  def test_ignores_unaddressed_message
    @router.handle_message(event("just chatting"))
    assert_empty @conn_a.deliveries
    assert_empty @conn_b.deliveries
    assert_equal TS, @store.last_seen(CH)
  end

  def test_owner_message_delivers_to_named_agent
    @router.handle_message(event("@#{A} do it"))
    assert_empty @conn_b.deliveries
    assert_equal({ channel: "epic-1-x", channel_id: CH, ts: TS, thread_ts: nil, sender: "UTAD",
                   sender_role: "owner", authority: "UTAD", text: "@#{A} do it", shared: [] },
                 @conn_a.deliveries.first)
  end

  def test_thread_ts_passes_through
    @router.handle_message(event("@#{A} do it", "thread_ts" => "1699999999.000001"))
    assert_equal "1699999999.000001", @conn_a.deliveries.first[:thread_ts]
  end

  def test_outsider_message_dropped_silently
    @router.handle_message(event("@#{A} do it", user: "UEVIL"))
    @router.handle_message(event("@all do it", user: "UEVIL"))
    assert_empty @conn_a.deliveries
    assert_empty @conn_b.deliveries
    assert_not_requested @post_stub
    assert_not_requested @reaction_stub
  end

  def test_authorized_user_reaches_only_their_agents_with_all
    @store.authorize(A, "UJANE")
    @router.handle_message(event("@all status?", user: "UJANE"))
    assert_empty @conn_b.deliveries
    delivery = @conn_a.deliveries.first
    assert_equal "authorized", delivery[:sender_role]
    assert_equal "UJANE", delivery[:authority]
  end

  def test_authorized_user_naming_unauthorized_agent_is_dropped
    @store.authorize(A, "UJANE")
    @router.handle_message(event("@#{B} status?", user: "UJANE"))
    assert_empty @conn_b.deliveries
    assert_empty @conn_a.deliveries
  end

  def link(ts: "p1700000000123456", channel: "C2", query: nil)
    "https://sixfifty.slack.com/archives/#{channel}/#{ts}#{query}"
  end

  def test_owner_permalink_shared_inline
    stub_slack(:get, "conversations.history",
               query: { "channel" => "C2", "latest" => "1700000000.123456", "inclusive" => "true", "limit" => "1" },
               response_body: { "messages" => [{ "user" => "UJANE", "text" => "the bug", "ts" => "1700000000.123456" }] })
    @router.handle_message(event("@#{A} see #{link}"))
    assert_equal [{ author: "UJANE", text: "the bug", ts: "1700000000.123456" }], @conn_a.deliveries.first[:shared]
  end

  def test_owner_thread_permalink_uses_replies_filtered_by_ts
    stub_slack(:get, "conversations.replies",
               query: hash_including("channel" => "C2", "ts" => "1700000000.000001"),
               response_body: { "messages" => [
                 { "user" => "UX", "text" => "parent", "ts" => "1700000000.000001" },
                 { "user" => "UJANE", "text" => "reply", "ts" => "1700000000.123456" }
               ] })
    @router.handle_message(event("@#{A} #{link(query: '?thread_ts=1700000000.000001&cid=C2')}"))
    assert_equal [{ author: "UJANE", text: "reply", ts: "1700000000.123456" }], @conn_a.deliveries.first[:shared]
  end

  def test_non_owner_permalink_not_fetched
    @store.authorize(A, "UJANE")
    history = stub_slack(:get, "conversations.history")
    @router.handle_message(event("@#{A} see #{link}", user: "UJANE"))
    assert_not_requested history
    assert_equal [], @conn_a.deliveries.first[:shared]
  end

  def test_permalink_fetch_failure_posts_thread_reply_and_still_delivers
    stub_slack(:get, "conversations.history", query: hash_including("channel" => "C2"),
                                              response_body: { "ok" => false, "error" => "channel_not_found" })
    @router.handle_message(event("@#{A} see #{link}", "thread_ts" => "1699999999.000001"))
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      body = JSON.parse(req.body)
      body["username"] == "conclave" && body["thread_ts"] == "1699999999.000001" &&
        body["text"].start_with?("Couldn't read linked message #{link}: ")
    end
    assert_equal [], @conn_a.deliveries.first[:shared]
  end

  def test_permalink_error_reply_threads_under_message_ts_when_top_level
    stub_slack(:get, "conversations.history", query: hash_including("channel" => "C2"),
                                              response_body: { "messages" => [] })
    @router.handle_message(event("@#{A} see #{link}"))
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      JSON.parse(req.body)["thread_ts"] == TS
    end
  end

  def test_invalid_thread_ts_is_a_fetch_failure_without_fetching
    history = stub_slack(:get, "conversations.history")
    replies = stub_slack(:get, "conversations.replies")
    @router.handle_message(event("@#{A} #{link(query: '?thread_ts=abc%26x')}"))
    assert_not_requested history
    assert_not_requested replies
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      JSON.parse(req.body)["text"].start_with?("Couldn't read linked message")
    end
    assert_equal [], @conn_a.deliveries.first[:shared]
  end

  def test_in_channel_authorize_consumed_not_delivered
    @router.handle_message(event("@#{A} authorize <@UJANE>"))
    assert @store.authorized?(A, "UJANE")
    assert_empty @conn_a.deliveries
    assert_requested @reaction_stub
  end

  def test_command_also_addressing_other_agents_is_still_consumed
    @router.handle_message(event("@#{B} @#{A} authorize <@UJANE>"))
    assert_empty @conn_a.deliveries
    assert_empty @conn_b.deliveries
  end

  def test_non_owner_cannot_authorize
    @store.authorize(A, "UJANE")
    @router.handle_message(event("@#{A} authorize <@UEVE>", user: "UJANE"))
    refute @store.authorized?(A, "UEVE")
  end
end

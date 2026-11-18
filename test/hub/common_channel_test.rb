# frozen_string_literal: true

require "test_helper"

class CommonChannelTest < Minitest::Test
  A = "tad_sc-1234"
  B = "tad_sc-5678"
  LIST_QUERY = { types: "public_channel,private_channel", exclude_archived: "true", limit: "200" }.freeze

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
    @common = build("conclave")
    @info = info_stub(is_private: false, is_member: false)
    @join = stub_slack(:post, "conversations.join", request_body: hash_including("channel" => "CCOM"))
    stub_slack(:post, "chat.postMessage", response_body: { "ts" => "5.5" })
    stub_slack(:post, "reactions.add")
    @page1 = list_stub([{ "id" => "C0", "name" => "random" }], next_cursor: "c2")
    @page2 = list_stub([{ "id" => "CCOM", "name" => "conclave" }], cursor: "c2")
  end

  def build(channel)
    Conclave::Hub::CommonChannel.new(store: @store, slack: @slack, notices: @notices, channel: channel)
  end

  def info_stub(is_private:, is_member:)
    stub_slack(:get, "conversations.info", query: { channel: "CCOM" },
                                           response_body: { "channel" => { "name" => "conclave", "is_private" => is_private,
                                                                           "is_member" => is_member } })
  end

  def list_stub(channels, cursor: nil, next_cursor: "")
    query = cursor ? LIST_QUERY.merge(cursor: cursor) : LIST_QUERY
    stub_slack(:get, "conversations.list", query: query,
                                           response_body: { "channels" => channels,
                                                            "response_metadata" => { "next_cursor" => next_cursor } })
  end

  def test_first_registration_joins_and_notifies_once
    conn = FakeConnection.new
    @agents.register(A, conn)
    assert_equal "CCOM", @common.ensure_joined(A)
    assert_nil @common.ensure_joined(A)
    assert_equal [A], @store.members("CCOM")
    assert @store.common_joined?(A)
    assert_requested @join, times: 1
    assert_equal(["tad_sc-1234: you joined #conclave, the common channel."], conn.deliveries.map { |m| m[:text] })
  end

  def test_name_is_resolved_once_across_pages
    @common.ensure_joined(A)
    @common.ensure_joined(B)
    assert_requested @page1, times: 1
    assert_requested @page2, times: 1
    assert_equal [A, B], @store.members("CCOM")
  end

  def test_name_with_hash_and_case_resolves
    assert_equal "CCOM", build("#Conclave").ensure_joined(A)
  end

  def test_id_is_used_without_lookup
    assert_equal "CCOM", build("CCOM").ensure_joined(A)
    assert_not_requested @page1
  end

  def test_removed_agent_is_not_rejoined
    @common.ensure_joined(A)
    @store.remove_membership(A, "CCOM")
    assert_nil @common.ensure_joined(A)
    assert_empty @store.memberships(A)
  end

  def test_unknown_channel_is_reported_and_retried
    list_stub([])
    _, err = capture_io { assert_nil @common.ensure_joined(A) }
    assert_match(/default_channel #conclave not found/, err)
    refute @store.common_joined?(A)

    list_stub([{ "id" => "CCOM", "name" => "conclave" }])
    assert_equal "CCOM", @common.ensure_joined(A)
  end

  def test_lookup_error_is_reported_and_retried
    stub_request(:get, "#{SLACK_BASE_URL}/conversations.list")
      .with(query: LIST_QUERY)
      .to_return(status: 200, body: { "ok" => false, "error" => "ratelimited" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    _, err = capture_io { assert_nil @common.ensure_joined(A) }
    assert_match(/common channel join failed for tad_sc-1234.*ratelimited/, err)
    refute @store.common_joined?(A)
    assert_not_requested @join

    list_stub([{ "id" => "CCOM", "name" => "conclave" }])
    assert_equal "CCOM", @common.ensure_joined(A)
  end

  def test_private_channel_without_app_is_reported_and_not_recorded
    info_stub(is_private: true, is_member: false)
    _, err = capture_io { assert_nil @common.ensure_joined(A) }
    assert_match(/common channel join failed for tad_sc-1234/, err)
    refute @store.common_joined?(A)
    assert_empty @store.memberships(A)
    assert_not_requested(:post, /chat\.postMessage/)
  end

  def test_slack_error_on_join_is_reported
    stub_slack(:post, "conversations.join", response_body: { "ok" => false, "error" => "ratelimited" })
    _, err = capture_io { assert_nil @common.ensure_joined(A) }
    assert_match(/common channel join failed for tad_sc-1234.*ratelimited/, err)
    refute @store.common_joined?(A)
    assert_empty @store.memberships(A)
  end
end

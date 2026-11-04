# frozen_string_literal: true

require "test_helper"

class SlackClientTest < Minitest::Test
  def setup
    @client = Conclave::Slack::Client.new(token: "xoxb-test")
  end

  def test_post_message_sends_username_and_icon
    stub = stub_slack(:post, "chat.postMessage", response_body: { "ts" => "1.2" },
                                                 request_body: hash_including("channel" => "C1", "text" => "hi",
                                                                              "username" => "tad_sc-1",
                                                                              "icon_emoji" => ":robot_face:"))
    result = @client.post_message(channel: "C1", text: "hi", username: "tad_sc-1", icon_emoji: ":robot_face:")
    assert_equal "1.2", result["ts"]
    assert_requested stub
  end

  def test_post_message_omits_nil_options
    stub = stub_slack(:post, "chat.postMessage")
    @client.post_message(channel: "C1", text: "hi")
    assert_requested(:post, "#{SLACK_BASE_URL}/chat.postMessage") do |req|
      JSON.parse(req.body) == { "channel" => "C1", "text" => "hi" }
    end
    assert_requested stub
  end

  def test_open_socket_connection_uses_own_token
    client = Conclave::Slack::Client.new(token: "xapp-1-test")
    stub = stub_slack(:post, "apps.connections.open", response_body: { "url" => "wss://x" },
                                                      headers: { "Authorization" => "Bearer xapp-1-test" })
    assert_equal "wss://x", client.open_socket_connection
    assert_requested stub
  end

  def test_auth_test
    stub_slack(:post, "auth.test", response_body: { "user_id" => "UBOT" })
    assert_equal "UBOT", @client.auth_test["user_id"]
  end

  def test_replies_and_history_use_get
    stub_slack(:get, "conversations.replies", query: { "channel" => "C1", "ts" => "1.0", "limit" => "50" },
                                              response_body: { "messages" => [] })
    stub_slack(:get, "conversations.history",
               query: { "channel" => "C1", "latest" => "9", "oldest" => "1", "inclusive" => "true", "limit" => "20" },
               response_body: { "messages" => [] })
    assert_equal [], @client.replies(channel: "C1", ts: "1.0")["messages"]
    assert_equal [], @client.history(channel: "C1", latest: "9", oldest: "1", inclusive: true)["messages"]
  end

  def test_channel_management
    stub_slack(:post, "conversations.create", request_body: hash_including("name" => "epic-1-x"),
                                              response_body: { "channel" => { "id" => "C9" } })
    stub_slack(:post, "conversations.invite", request_body: hash_including("channel" => "C9", "users" => "U1,U2"))
    stub_slack(:post, "conversations.join", request_body: hash_including("channel" => "C9"))
    stub_slack(:post, "reactions.add", request_body: hash_including("channel" => "C9", "timestamp" => "1.0",
                                                                    "name" => "zzz"))
    stub_slack(:get, "conversations.info", query: { "channel" => "C9" },
                                           response_body: { "channel" => { "id" => "C9" } })
    assert_equal "C9", @client.create_channel(name: "epic-1-x").dig("channel", "id")
    assert @client.invite(channel: "C9", users: %w[U1 U2])["ok"]
    assert @client.join(channel: "C9")["ok"]
    assert @client.add_reaction(channel: "C9", ts: "1.0", name: "zzz")["ok"]
    assert_equal "C9", @client.channel_info(channel: "C9").dig("channel", "id")
  end

  def test_slack_error_raises
    stub_slack(:post, "auth.test", response_body: { "ok" => false, "error" => "invalid_auth" })
    assert_raises(Conclave::Slack::Client::AuthenticationError) { @client.auth_test }
  end

  def test_rate_limit_retries_once
    stub_request(:post, "#{SLACK_BASE_URL}/auth.test")
      .to_return({ status: 429, headers: { "Retry-After" => "1" } },
                 { status: 200, body: { ok: true }.to_json })
    @client.define_singleton_method(:sleep) { |_seconds| nil }
    assert @client.auth_test["ok"]
  end
end

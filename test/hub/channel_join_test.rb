# frozen_string_literal: true

require "test_helper"

class ChannelJoinTest < Minitest::Test
  Join = Conclave::Hub::ChannelJoin

  def setup
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
  end

  def info(is_private:, is_member:)
    stub_slack(:get, "conversations.info", query: { channel: "C1" },
                                           response_body: { "channel" => { "is_private" => is_private,
                                                                           "is_member" => is_member } })
  end

  def test_public_channel_is_joined
    info(is_private: false, is_member: false)
    join = stub_slack(:post, "conversations.join", request_body: hash_including("channel" => "C1"))
    Join.ensure(@slack, "C1")
    assert_requested join
  end

  def test_private_channel_with_app_is_not_joined
    info(is_private: true, is_member: true)
    join = stub_slack(:post, "conversations.join")
    Join.ensure(@slack, "C1")
    assert_not_requested join
  end

  def test_private_channel_without_app_raises_private
    info(is_private: true, is_member: false)
    assert_raises(Join::Private) { Join.ensure(@slack, "C1") }
  end

  def test_join_refused_for_channel_type_raises_private
    info(is_private: false, is_member: false)
    stub_slack(:post, "conversations.join",
               response_body: { "ok" => false, "error" => "method_not_supported_for_channel_type" })
    assert_raises(Join::Private) { Join.ensure(@slack, "C1") }
  end

  def test_other_slack_errors_propagate
    info(is_private: false, is_member: false)
    stub_slack(:post, "conversations.join", response_body: { "ok" => false, "error" => "ratelimited" })
    assert_raises(Conclave::Slack::Client::Error) { Join.ensure(@slack, "C1") }
  end
end

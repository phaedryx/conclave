# frozen_string_literal: true

require "test_helper"

class CommandsTest < Minitest::Test
  A = "tad_sc-1234"
  CH = "C1"

  def setup
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @commands = Conclave::Hub::Commands.new(store: @store, authority: @authority, slack: @slack, owner: "UTAD")
    @store.add_membership(A, CH)
  end

  def event(text, user: "UTAD")
    { "type" => "message", "user" => user, "text" => text, "channel" => CH, "ts" => "1700000000.000100" }
  end

  def slash(text, user: "UTAD")
    { "user_id" => user, "channel_id" => CH, "text" => text }
  end

  def channel_info_stub(channel, is_private: false, is_member: false)
    stub_slack(:get, "conversations.info", query: { channel: channel },
                                           response_body: { "channel" => { "id" => channel, "is_private" => is_private,
                                                                           "is_member" => is_member } })
  end

  def reaction_stub(name)
    stub_slack(:post, "reactions.add", request_body: hash_including("name" => name, "channel" => CH))
  end

  def test_slash_invite_joins_and_adds_membership
    channel_info_stub("C2")
    join = stub_slack(:post, "conversations.join", request_body: hash_including("channel" => "C2"))
    @commands.handle_slash({ "user_id" => "UTAD", "channel_id" => "C2", "text" => "invite tad_sc-9" })
    assert_requested join
    assert_equal ["C2"], @store.memberships("tad_sc-9")
  end

  def test_slash_invite_private_channel_message
    channel_info_stub(CH)
    stub_slack(:post, "conversations.join",
               response_body: { "ok" => false, "error" => "method_not_supported_for_channel_type" })
    reply = @commands.handle_slash(slash("invite tad_sc-9"))
    assert_equal "Add the Conclave app to this private channel first.", reply
    assert_empty @store.memberships("tad_sc-9")
  end

  def test_slash_invite_private_channel_with_bot_adds_membership_without_join
    channel_info_stub(CH, is_private: true, is_member: true)
    join = stub_slack(:post, "conversations.join")
    reply = @commands.handle_slash(slash("invite tad_sc-9"))
    assert_equal "tad_sc-9 invited to this channel.", reply
    assert_equal [CH], @store.memberships("tad_sc-9")
    assert_not_requested join
  end

  def test_slash_invite_private_channel_without_bot_asks_for_app
    channel_info_stub(CH, is_private: true, is_member: false)
    join = stub_slack(:post, "conversations.join")
    reply = @commands.handle_slash(slash("invite tad_sc-9"))
    assert_equal "Add the Conclave app to this private channel first.", reply
    assert_empty @store.memberships("tad_sc-9")
    assert_not_requested join
  end

  def test_slash_invite_other_slack_error_reports_and_does_not_add
    channel_info_stub(CH)
    stub_slack(:post, "conversations.join", response_body: { "ok" => false, "error" => "ratelimited" })
    assert_match(/Couldn't join/, @commands.handle_slash(slash("invite tad_sc-9")))
    assert_empty @store.memberships("tad_sc-9")
  end

  def test_slash_agent_names_are_lowercased
    channel_info_stub(CH)
    stub_slack(:post, "conversations.join")
    assert_equal "tad_sc-9 invited to this channel.", @commands.handle_slash(slash("invite TAD_SC-9"))
    assert_equal [CH], @store.memberships("tad_sc-9")
    @commands.handle_slash(slash("remove Tad_Sc-9"))
    assert_empty @store.memberships("tad_sc-9")
    assert_equal "Authorized <@UJANE> for tad_sc-777.", @commands.handle_slash(slash("authorize TAD_sc-777 <@UJANE>"))
    assert @store.authorized?("tad_sc-777", "UJANE")
    @commands.handle_slash(slash("deauthorize Tad_SC-777 <@UJANE>"))
    refute @store.authorized?("tad_sc-777", "UJANE")
  end

  def test_slash_remove
    @commands.handle_slash(slash("remove #{A}"))
    assert_empty @store.members(CH)
  end

  def test_slash_authorize_and_deauthorize_accept_any_agent_name
    @commands.handle_slash(slash("authorize tad_sc-777 <@UJANE>"))
    assert @store.authorized?("tad_sc-777", "UJANE")
    @commands.handle_slash(slash("deauthorize tad_sc-777 <@UJANE|jane>"))
    refute @store.authorized?("tad_sc-777", "UJANE")
  end

  def test_slash_from_non_owner_answers_only_tad_and_changes_nothing
    stub = stub_slack(:post, "conversations.join")
    ["invite #{A}", "remove #{A}", "authorize #{A} <@UJANE>", "nonsense"].each do |text|
      assert_equal "Only Tad can do that.", @commands.handle_slash(slash(text, user: "UJANE"))
    end
    assert_not_requested stub
    refute @store.authorized?(A, "UJANE")
    assert_equal [A], @store.members(CH)
  end

  def test_slash_unparseable_returns_usage
    expected = "Usage: /conclave invite <agent> | remove <agent> | authorize <agent> @person | " \
               "deauthorize <agent> @person"
    ["", "frobnicate", "invite", "authorize #{A}", "authorize #{A} jane"].each do |text|
      assert_equal expected, @commands.handle_slash(slash(text))
    end
  end

  def test_in_channel_authorize_grants_and_reacts
    stub = reaction_stub("white_check_mark")
    assert @commands.handle_text(event("#{A}: authorize <@UJANE>"))
    assert @store.authorized?(A, "UJANE")
    assert_requested stub
  end

  def test_in_channel_deauthorize_revokes
    @store.authorize(A, "UJANE")
    reaction_stub("white_check_mark")
    assert @commands.handle_text(event("#{A}: deauthorize <@UJANE>"))
    refute @store.authorized?(A, "UJANE")
  end

  def test_non_owner_cannot_authorize
    stub = stub_slack(:post, "reactions.add")
    refute @commands.handle_text(event("#{A}: authorize <@UJANE>", user: "UJANE"))
    refute @store.authorized?(A, "UJANE")
    assert_not_requested stub
  end

  def test_in_channel_authorize_for_non_member_agent_reacts_x_and_does_nothing
    stub = reaction_stub("x")
    assert @commands.handle_text(event("tad_sc-9999: authorize <@UJANE>"))
    refute @store.authorized?("tad_sc-9999", "UJANE")
    assert_requested stub
  end

  def test_ordinary_text_is_not_a_command
    refute @commands.handle_text(event("#{A}: please authorize the build"))
    refute @commands.handle_text(event("@#{A} authorize <@UJANE>")), "the old @ form is not a command"
    refute @commands.handle_text(event("hey #{A}: authorize <@UJANE>")), "the name must start the message"
    refute @commands.handle_text(event("hello"))
    refute @commands.handle_text({ "text" => "x" })
  end
end

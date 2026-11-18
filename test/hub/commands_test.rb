# frozen_string_literal: true

require "test_helper"

class CommandsTest < Minitest::Test
  A = "tad_sc-1234"
  CH = "C1"
  BAD_NAME = "Channel names are lowercase letters, numbers, hyphens and underscores, up to 80 characters."

  class FakeNotices
    attr_reader :added_calls, :consult_calls

    def initialize
      @added_calls = []
      @consult_calls = []
    end

    def consulted(*args) = @consult_calls << [:consulted, *args]

    def unconsulted(*args) = @consult_calls << [:unconsulted, *args]

    def added(names, channel_id)
      @added_calls << [names, channel_id]
    end
  end

  def setup
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @notices = FakeNotices.new
    @commands = Conclave::Hub::Commands.new(store: @store, authority: @authority, slack: @slack, owner: "UTAD",
                                            notices: @notices)
    @store.add_membership(A, CH)
    user_info_stub("UJANE", "is_bot" => false)
  end

  def user_info_stub(user, fields)
    stub_slack(:get, "users.info", query: { "user" => user }, response_body: { "user" => { "id" => user }.merge(fields) })
  end

  def taude_stub
    user_info_stub("UTAUDE", "is_bot" => true, "real_name" => "Taude",
                             "profile" => { "bot_id" => "BTAUDE", "display_name" => "" })
  end

  def create_stub(name = "billing-rework")
    stub_slack(:post, "conversations.create", request_body: { name: name, is_private: false },
                                              response_body: { "channel" => { "id" => "CNEW" } })
  end

  def invite_stub
    stub_slack(:post, "conversations.invite", request_body: { channel: "CNEW", users: "UTAD" })
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

  def test_slash_invite_sends_notice
    channel_info_stub("C2")
    stub_slack(:post, "conversations.join")
    @commands.handle_slash({ "user_id" => "UTAD", "channel_id" => "C2", "text" => "invite tad_sc-9" })
    assert_equal [[["tad_sc-9"], "C2"]], @notices.added_calls
  end

  def test_slash_invite_of_a_member_says_so_and_sends_no_notice
    join = stub_slack(:post, "conversations.join")
    assert_equal "tad_sc-1234 is already in this channel.", @commands.handle_slash(slash("invite #{A}"))
    assert_not_requested join
    assert_empty @notices.added_calls
  end

  def test_slash_invite_failure_sends_no_notice
    channel_info_stub(CH, is_private: true, is_member: false)
    @commands.handle_slash(slash("invite tad_sc-9"))
    assert_empty @notices.added_calls
  end

  def test_slash_channel_creates_invites_tad_adds_agents_and_notifies
    @store.remember_agent(A)
    @store.remember_agent("coord")
    create = create_stub
    invite = invite_stub
    reply = @commands.handle_slash(slash("channel billing-rework #{A} coord"))
    assert_equal "Created #billing-rework with tad_sc-1234, coord.", reply
    assert_requested create
    assert_requested invite
    assert_equal [A, "coord"], @store.members("CNEW")
    assert_equal [[[A, "coord"], "CNEW"]], @notices.added_calls
  end

  def test_slash_channel_normalizes_name_and_dedupes_agents
    @store.remember_agent(A)
    create_stub
    invite_stub
    reply = @commands.handle_slash(slash("channel #Billing-Rework #{A} TAD_SC-1234"))
    assert_equal "Created #billing-rework with tad_sc-1234.", reply
    assert_equal [A], @store.members("CNEW")
    assert_equal [[[A], "CNEW"]], @notices.added_calls
  end

  def test_slash_channel_rejects_unknown_agents_and_creates_nothing
    @store.remember_agent(A)
    create = create_stub("x")
    assert_equal "Unknown agent: coord.", @commands.handle_slash(slash("channel x #{A} coord"))
    assert_equal "Unknown agents: coord, nobody.", @commands.handle_slash(slash("channel x coord nobody"))
    assert_not_requested create
    assert_empty @notices.added_calls
  end

  def test_slash_channel_rejects_bad_names
    @store.remember_agent(A)
    create = stub_slack(:post, "conversations.create")
    ["channel bad.name #{A}", "channel #{'x' * 81} #{A}", "channel has\u00a0space #{A}"].each do |text|
      assert_equal BAD_NAME, @commands.handle_slash(slash(text)), text
    end
    assert_not_requested create
  end

  def test_slash_channel_name_taken_points_to_invite
    @store.remember_agent(A)
    stub_slack(:post, "conversations.create", response_body: { "ok" => false, "error" => "name_taken" })
    reply = @commands.handle_slash(slash("channel billing-rework #{A}"))
    assert_equal "#billing-rework already exists. Run /conclave invite from inside it.", reply
    assert_equal [CH], @store.memberships(A)
    assert_empty @notices.added_calls
  end

  def test_slash_channel_other_create_error
    @store.remember_agent(A)
    stub_slack(:post, "conversations.create", response_body: { "ok" => false, "error" => "ratelimited" })
    reply = @commands.handle_slash(slash("channel billing-rework #{A}"))
    assert_equal "Couldn't create #billing-rework: Slack API error: ratelimited", reply
  end

  def test_slash_channel_reports_failed_owner_invite_in_reply
    @store.remember_agent(A)
    create_stub
    stub_slack(:post, "conversations.invite", response_body: { "ok" => false, "error" => "already_in_channel" })
    reply = @commands.handle_slash(slash("channel billing-rework #{A}"))
    assert_equal "Created #billing-rework with tad_sc-1234. Couldn't invite you: Slack API error: already_in_channel",
                 reply
    assert_equal [A], @store.members("CNEW")
    assert_equal [[[A], "CNEW"]], @notices.added_calls
  end

  def test_slash_channel_without_agents_is_usage
    assert_equal Conclave::Hub::Commands::USAGE, @commands.handle_slash(slash("channel billing-rework"))
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
    expected = "Usage: /conclave invite <agent> | remove <agent> | channel <name> <agent> [<agent>…] | " \
               "authorize <agent> @person | deauthorize <agent> @person | consult <agent> @bot | unconsult <agent> @bot"
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

  def test_slash_consult_and_unconsult
    taude_stub
    assert_equal "Consulted <@UTAUDE> for tad_sc-777.", @commands.handle_slash(slash("consult TAD_sc-777 <@UTAUDE>"))
    assert @store.consults?("tad_sc-777", "BTAUDE")
    refute @store.authorized?("tad_sc-777", "UTAUDE")
    assert_equal "Unconsulted <@UTAUDE> for tad_sc-777.", @commands.handle_slash(slash("unconsult tad_sc-777 <@UTAUDE>"))
    refute @store.consults?("tad_sc-777", "BTAUDE")
    assert_equal [[:consulted, "tad_sc-777", "Taude", "UTAUDE", CH], [:unconsulted, "tad_sc-777", "Taude", "UTAUDE", CH]],
                 @notices.consult_calls
  end

  def test_display_name_wins_over_real_name
    user_info_stub("UTAUDE", "is_bot" => true, "real_name" => "Taude",
                             "profile" => { "bot_id" => "BTAUDE", "display_name" => "taude-bot" })
    @commands.handle_slash(slash("consult #{A} <@UTAUDE>"))
    assert_equal "taude-bot", @notices.consult_calls.first[2]
  end

  def test_unconsult_without_a_grant_posts_no_notice
    taude_stub
    assert_equal "Unconsulted <@UTAUDE> for #{A}.", @commands.handle_slash(slash("unconsult #{A} <@UTAUDE>"))
    assert_empty @notices.consult_calls
  end

  def test_unconsult_notice_falls_back_to_no_name_when_lookup_fails
    @store.consult(A, "UGONE", "BGONE")
    stub_slack(:get, "users.info", query: { "user" => "UGONE" }, response_body: { "ok" => false, "error" => "user_not_found" })
    assert_equal "Unconsulted <@UGONE> for #{A}.", @commands.handle_slash(slash("unconsult #{A} <@UGONE>"))
    assert_equal [[:unconsulted, A, nil, "UGONE", CH]], @notices.consult_calls
  end

  def test_refused_consult_posts_no_notice
    @commands.handle_slash(slash("consult #{A} <@UJANE>"))
    assert_empty @notices.consult_calls
  end

  def test_deauthorize_does_not_look_up_the_user
    stub = user_info_stub("UTAUDE", "is_bot" => true)
    @commands.handle_slash(slash("deauthorize #{A} <@UTAUDE>"))
    assert_not_requested stub
  end

  def test_in_channel_consult_grants_and_reacts
    taude_stub
    stub = reaction_stub("white_check_mark")
    assert @commands.handle_text(event("#{A}: consult <@UTAUDE>"))
    assert @store.consults?(A, "BTAUDE")
    assert_equal [[:consulted, A, "Taude", "UTAUDE", CH]], @notices.consult_calls
    assert_requested stub
  end

  def test_authorize_refuses_a_bot
    taude_stub
    assert_equal "<@UTAUDE> is a bot. Use consult for bots.", @commands.handle_slash(slash("authorize #{A} <@UTAUDE>"))
    stub = reaction_stub("x")
    assert @commands.handle_text(event("#{A}: authorize <@UTAUDE>"))
    assert_requested stub
    refute @store.authorized?(A, "UTAUDE")
  end

  def test_consult_refuses_a_person
    user_info_stub("UJANE", "is_bot" => false, "profile" => { "bot_id" => "BJANE" })
    assert_equal "<@UJANE> isn't a bot. Use authorize for people.", @commands.handle_slash(slash("consult #{A} <@UJANE>"))
    refute @store.consults?(A, "BJANE")
  end

  def test_lookup_without_a_user_refuses
    stub_slack(:get, "users.info", query: { "user" => "UODD" })
    assert_equal "Couldn't look up <@UODD>: no user", @commands.handle_slash(slash("authorize #{A} <@UODD>"))
    refute @store.authorized?(A, "UODD")
  end

  def test_consult_refuses_a_bot_without_a_bot_id
    user_info_stub("UTAUDE", "is_bot" => true, "profile" => {})
    assert_equal "Couldn't find <@UTAUDE>'s bot id.", @commands.handle_slash(slash("consult #{A} <@UTAUDE>"))
  end

  def test_user_lookup_failure_refuses
    stub_slack(:get, "users.info", query: { "user" => "UGONE" }, response_body: { "ok" => false, "error" => "user_not_found" })
    assert_equal "Couldn't look up <@UGONE>: user_not_found", @commands.handle_slash(slash("authorize #{A} <@UGONE>"))
    assert_equal "Couldn't look up <@UGONE>: user_not_found", @commands.handle_slash(slash("consult #{A} <@UGONE>"))
    refute @store.authorized?(A, "UGONE")
  end

  def test_ordinary_text_is_not_a_command
    refute @commands.handle_text(event("#{A}: please authorize the build"))
    refute @commands.handle_text(event("@#{A} authorize <@UJANE>")), "the old @ form is not a command"
    refute @commands.handle_text(event("hey #{A}: authorize <@UJANE>")), "the name must start the message"
    refute @commands.handle_text(event("hello"))
    refute @commands.handle_text({ "text" => "x" })
  end
end

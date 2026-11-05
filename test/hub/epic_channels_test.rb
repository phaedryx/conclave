# frozen_string_literal: true

require "test_helper"

class EpicChannelsTest < Minitest::Test
  A = "tad_sc-1234"
  B = "tad_sc-1235"

  class FakeShortcut
    def initialize(epics)
      @epics = epics
    end

    def epic_for_story(story_id)
      result = @epics.fetch(story_id, nil)
      raise result if result.is_a?(Exception)

      result
    end
  end

  def setup
    @store = Conclave::Store.new(":memory:")
    @slack = Conclave::Slack::Client.new(token: "xoxb-test")
    @shortcut = FakeShortcut.new(1234 => { id: 77, name: "Payroll Sync!" }, 1235 => { id: 77, name: "Payroll Sync!" },
                                 1 => nil)
    @epics = build(@shortcut)
  end

  def build(shortcut)
    Conclave::Hub::EpicChannels.new(store: @store, slack: @slack, shortcut: shortcut, owner: "UTAD")
  end

  def slack_error_stub(path, code)
    stub_request(:post, "#{SLACK_BASE_URL}/#{path}")
      .to_return(status: 200, body: { "ok" => false, "error" => code }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def test_creates_channel_and_invites_owner_once
    create = stub_slack(:post, "conversations.create", request_body: { name: "epic-77-payroll-sync", is_private: false },
                                                       response_body: { "channel" => { "id" => "CEPIC" } })
    invite = stub_slack(:post, "conversations.invite", request_body: { channel: "CEPIC", users: "UTAD" })

    assert_equal "CEPIC", @epics.ensure_joined(A)
    assert_equal "CEPIC", @epics.ensure_joined(B)

    assert_requested create, times: 1
    assert_requested invite, times: 1
    assert_equal [A, B], @store.members("CEPIC")
    assert @store.epic_joined?(A)
    assert_equal "CEPIC", @store.epic_channel(77)
  end

  def test_no_epic_no_join
    assert_nil @epics.ensure_joined("tad_sc-1")
    assert_nil @epics.ensure_joined("no-story")
    assert_empty @store.memberships("tad_sc-1")
    refute @store.epic_joined?("tad_sc-1")
  end

  def test_already_joined_does_nothing
    @store.mark_epic_joined(A)
    assert_nil @epics.ensure_joined(A)
  end

  def test_name_taken_retries_once_with_epic_id_suffix
    stub_slack(:post, "conversations.create", request_body: { name: "epic-77-payroll-sync", is_private: false })
      .to_return(body: { "ok" => false, "error" => "name_taken" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    retry_stub = stub_slack(:post, "conversations.create",
                            request_body: { name: "epic-77-payroll-sync-77", is_private: false },
                            response_body: { "channel" => { "id" => "C2" } })
    stub_slack(:post, "conversations.invite")

    assert_equal "C2", @epics.ensure_joined(A)
    assert_requested retry_stub, times: 1
    assert_equal "C2", @store.epic_channel(77)
  end

  def test_suffixed_name_truncated_to_80_chars_keeping_suffix
    long = FakeShortcut.new(1234 => { id: 77, name: "x" * 200 })
    epics = build(long)
    names = []
    stub_request(:post, "#{SLACK_BASE_URL}/conversations.create").to_return do |request|
      names << JSON.parse(request.body)["name"]
      if names.size == 1
        { body: { "ok" => false, "error" => "name_taken" }.to_json, headers: { "Content-Type" => "application/json" } }
      else
        { body: { "ok" => true, "channel" => { "id" => "C3" } }.to_json,
          headers: { "Content-Type" => "application/json" } }
      end
    end
    stub_slack(:post, "conversations.invite")

    assert_equal "C3", epics.ensure_joined(A)
    assert_equal 80, names.first.length
    assert_equal 80, names.last.length
    assert names.last.end_with?("-77")
  end

  def test_second_name_taken_raises
    slack_error_stub("conversations.create", "name_taken")
    assert_raises(Conclave::Slack::Client::Error) { @epics.ensure_joined(A) }
    refute @store.epic_joined?(A)
  end

  def test_invite_failure_is_best_effort
    stub_slack(:post, "conversations.create", response_body: { "channel" => { "id" => "CEPIC" } })
    slack_error_stub("conversations.invite", "already_in_channel")
    _out, err = capture_io { assert_equal "CEPIC", @epics.ensure_joined(A) }
    assert_match(/already_in_channel/, err)
    assert @store.epic_joined?(A)
  end

  def test_shortcut_error_returns_nil_and_logs
    epics = build(FakeShortcut.new(1234 => Conclave::Shortcut::Client::Error.new("boom")))
    _out, err = capture_io { assert_nil epics.ensure_joined(A) }
    assert_match(/boom/, err)
    refute @store.epic_joined?(A)
  end
end

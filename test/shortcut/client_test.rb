# frozen_string_literal: true

require "test_helper"

class ShortcutClientTest < Minitest::Test
  def setup
    @client = Conclave::Shortcut::Client.new(token: "sc-token")
  end

  def test_epic_for_story
    stub_shortcut("stories/1234", response_body: { "id" => 1234, "epic_id" => 77 })
    stub_shortcut("epics/77", response_body: { "id" => 77, "name" => "Payroll Sync" })
    assert_equal({ id: 77, name: "Payroll Sync" }, @client.epic_for_story(1234))
  end

  def test_epic_for_story_without_epic
    stub_shortcut("stories/1234", response_body: { "id" => 1234, "epic_id" => nil })
    assert_nil @client.epic_for_story(1234)
  end

  def test_unknown_story_returns_nil
    stub_shortcut("stories/9", response_body: {}, status: 404)
    assert_nil @client.epic_for_story(9)
  end

  def test_server_error_raises
    stub_shortcut("stories/9", response_body: {}, status: 500)
    assert_raises(Conclave::Shortcut::Client::Error) { @client.epic_for_story(9) }
  end
end

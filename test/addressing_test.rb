# frozen_string_literal: true

require "test_helper"

class AddressingTest < Minitest::Test
  MEMBERS = %w[tad_sc-1234 tad_sc-5678].freeze

  def parse(text, members: MEMBERS)
    Conclave::Addressing.parse(text, members: members)
  end

  def test_named_agent
    assert_equal ["tad_sc-1234"], parse("hey @tad_sc-1234 look")[:agents]
  end

  def test_case_insensitive
    assert_equal ["tad_sc-1234"], parse("hey @TAD_SC-1234 look")[:agents]
  end

  def test_word_boundaries
    assert_empty parse("@tad_sc-12345", members: ["tad_sc-1234"])[:agents]
    assert_empty parse("email@tad_sc-1234.com", members: ["tad_sc-1234"])[:agents]
  end

  def test_trailing_punctuation_still_matches
    assert_equal ["tad_sc-1234"], parse("@tad_sc-1234, look")[:agents]
    assert_equal ["tad_sc-1234"], parse("ping @tad_sc-1234.")[:agents]
  end

  def test_agents_in_order_of_appearance_deduplicated
    result = parse("@tad_sc-5678 then @tad_sc-1234 and @tad_sc-5678 again")
    assert_equal %w[tad_sc-5678 tad_sc-1234], result[:agents]
  end

  def test_slack_user_mentions_are_not_agents
    assert_equal({ agents: [], all: false }, parse("<@U123> hi"))
  end

  def test_all_variants
    ["@all", "@ALL hands", "<!here>", "<!channel>"].each do |text|
      assert parse(text)[:all], "expected all for #{text.inspect}"
    end
  end

  def test_all_respects_boundaries
    refute parse("@allison hi")[:all]
    refute parse("mail@all.com")[:all]
  end

  def test_unaddressed
    assert_equal({ agents: [], all: false }, parse("lunch?"))
  end
end

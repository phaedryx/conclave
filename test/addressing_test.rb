# frozen_string_literal: true

require "test_helper"

class AddressingTest < Minitest::Test
  MEMBERS = %w[tad_sc-1234 tad_sc-5678].freeze
  NOBODY = { agents: [], all: false }.freeze

  def parse(text, members: MEMBERS)
    Conclave::Addressing.parse(text, members: members)
  end

  def test_name_prefix_addresses_the_agent
    assert_equal({ agents: ["tad_sc-1234"], all: false }, parse("tad_sc-1234: look"))
  end

  def test_case_insensitive
    assert_equal ["tad_sc-1234"], parse("TAD_SC-1234: look")[:agents]
  end

  def test_name_must_start_the_message
    assert_empty parse("hey tad_sc-1234: look")[:agents]
    assert_empty parse("I told tad_sc-1234: nothing")[:agents]
  end

  def test_leading_whitespace_and_space_before_the_colon_are_tolerated
    assert_equal ["tad_sc-1234"], parse("  \ntad_sc-1234 : look")[:agents]
    assert_equal ["tad_sc-1234"], parse("tad_sc-1234:look")[:agents]
  end

  def test_whole_name_must_match
    assert_empty parse("tad_sc-12345: x", members: ["tad_sc-1234"])[:agents]
    assert_empty parse("tad_sc-123: x", members: ["tad_sc-1234"])[:agents]
  end

  def test_comma_list_in_order_deduplicated
    assert_equal %w[tad_sc-5678 tad_sc-1234], parse("tad_sc-5678, tad_sc-1234,tad_sc-5678: hi")[:agents]
  end

  def test_unknown_names_in_the_list_are_ignored
    assert_equal ["tad_sc-1234"], parse("bob, tad_sc-1234: hi")[:agents]
    assert_equal NOBODY, parse("bob: hi")
  end

  def test_all
    ["all: hands", "ALL: hands", "all:", "all, tad_sc-1234: hi", "tad_sc-1234, all: hi"].each do |text|
      assert parse(text)[:all], "expected all for #{text.inspect}"
    end
  end

  def test_all_must_be_the_whole_name
    refute parse("allison: hi", members: ["allison"])[:all]
    refute parse("all-hands: hi")[:all]
  end

  def test_at_mentions_no_longer_address
    ["@tad_sc-1234 hi", "@all hi", "<!here> hi", "<!channel> hi", "<@U123> hi"].each do |text|
      assert_equal NOBODY, parse(text), text.inspect
    end
  end

  def test_other_leading_colons_are_not_addressing
    assert_equal NOBODY, parse(":wave: tad_sc-1234: hi")
    assert_equal NOBODY, parse("https://example.com tad_sc-1234")
  end

  def test_unaddressed
    assert_equal NOBODY, parse("lunch?")
    assert_equal NOBODY, parse("")
    assert_equal NOBODY, parse(nil)
  end
end

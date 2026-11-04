# frozen_string_literal: true

require "test_helper"

class AgentNameTest < Minitest::Test
  def test_from_worktree_strips_slug
    assert_equal "tad_sc-1234", Conclave::AgentName.from_worktree("tad_sc-1234-fix-the-thing")
  end

  def test_from_worktree_bare_story
    assert_equal "tad_sc-1234", Conclave::AgentName.from_worktree("tad_sc-1234")
  end

  def test_from_worktree_without_story_uses_full_name
    assert_equal "coord", Conclave::AgentName.from_worktree("coord")
  end

  def test_story_id
    assert_equal 1234, Conclave::AgentName.story_id("tad_sc-1234")
  end

  def test_story_id_nil_without_story
    assert_nil Conclave::AgentName.story_id("coord")
  end
end

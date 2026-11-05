# frozen_string_literal: true

require "test_helper"

class StoreTest < Minitest::Test
  def setup
    @store = Conclave::Store.new(":memory:")
  end

  def test_epic_channel_round_trip
    assert_nil @store.epic_channel(42)
    @store.set_epic_channel(42, "C1")
    assert_equal "C1", @store.epic_channel(42)
    @store.set_epic_channel(42, "C2")
    assert_equal "C2", @store.epic_channel(42)
  end

  def test_memberships_round_trip_in_insertion_order
    @store.add_membership("a", "C2")
    @store.add_membership("a", "C1")
    @store.add_membership("b", "C1")
    assert_equal %w[C2 C1], @store.memberships("a")
    assert_equal %w[a b], @store.members("C1")
    @store.remove_membership("a", "C2")
    assert_equal %w[C1], @store.memberships("a")
  end

  def test_add_membership_is_idempotent
    2.times { @store.add_membership("a", "C1") }
    assert_equal %w[C1], @store.memberships("a")
  end

  def test_post_authority_round_trip
    assert_nil @store.post_authority("C1", "1.1")
    @store.record_post_authority("C1", "1.1", "UTAD")
    @store.record_post_authority("C1", "1.2", :none)
    assert_equal "UTAD", @store.post_authority("C1", "1.1")
    assert_equal :none, @store.post_authority("C1", "1.2")
    assert_nil @store.post_authority("C2", "1.1")
  end

  def test_epic_joined
    refute @store.epic_joined?("a")
    @store.mark_epic_joined("a")
    @store.mark_epic_joined("a")
    assert @store.epic_joined?("a")
  end

  def test_remove_after_epic_join_sticks
    @store.add_membership("a", "C1")
    @store.mark_epic_joined("a")
    @store.remove_membership("a", "C1")
    assert @store.epic_joined?("a")
    assert_empty @store.memberships("a")
  end

  def test_authorize_round_trip
    refute @store.authorized?("a", "U1")
    @store.authorize("a", "U1")
    @store.authorize("a", "U1")
    @store.authorize("b", "U1")
    assert @store.authorized?("a", "U1")
    assert_equal %w[a b], @store.authorized_agents("U1")
    @store.deauthorize("a", "U1")
    refute @store.authorized?("a", "U1")
    assert_equal %w[b], @store.authorized_agents("U1")
  end

  def test_enqueue_and_drain_fifo
    @store.enqueue("a", { "text" => "one", "n" => 1 }, limit: 10)
    @store.enqueue("a", { text: "two" }, limit: 10)
    @store.enqueue("b", { "text" => "other" }, limit: 10)
    assert_equal [{ "text" => "one", "n" => 1 }, { "text" => "two" }], @store.drain("a")
    assert_empty @store.drain("a")
    assert_equal [{ "text" => "other" }], @store.drain("b")
  end

  def test_enqueue_caps_and_drops_oldest
    %w[one two three].each { |t| @store.enqueue("a", { "text" => t }, limit: 2) }
    assert_equal [{ "text" => "two" }, { "text" => "three" }], @store.drain("a")
  end

  def test_enqueue_cap_is_per_agent
    @store.enqueue("a", { "n" => 1 }, limit: 1)
    @store.enqueue("b", { "n" => 2 }, limit: 1)
    assert_equal [{ "n" => 1 }], @store.drain("a")
  end

  def test_channels_with_last_seen_lists_pairs
    assert_empty @store.channels_with_last_seen
    @store.set_last_seen("C2", "2.2")
    @store.set_last_seen("C1", "1.1")
    @store.set_last_seen("C1", "1.5")
    assert_equal [%w[C1 1.5], %w[C2 2.2]], @store.channels_with_last_seen
  end

  def test_last_seen_round_trip
    assert_nil @store.last_seen("C1")
    @store.set_last_seen("C1", "1.1")
    @store.set_last_seen("C1", "2.2")
    assert_equal "2.2", @store.last_seen("C1")
  end

  def test_forget_clears_everything
    @store.add_membership("a", "C1")
    @store.add_membership("b", "C1")
    @store.mark_epic_joined("a")
    @store.authorize("a", "U1")
    @store.authorize("b", "U1")
    @store.enqueue("a", { "x" => 1 }, limit: 5)
    @store.forget("a")
    assert_empty @store.memberships("a")
    refute @store.epic_joined?("a")
    refute @store.authorized?("a", "U1")
    assert_empty @store.drain("a")
    assert_equal %w[b], @store.members("C1")
    assert @store.authorized?("b", "U1")
  end

  def test_file_db_persists
    Dir.mktmpdir do |dir|
      path = File.join(dir, "conclave.db")
      Conclave::Store.new(path).add_membership("a", "C1")
      assert_equal %w[C1], Conclave::Store.new(path).memberships("a")
    end
  end
end

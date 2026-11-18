# frozen_string_literal: true

require "test_helper"

class StoreTest < Minitest::Test
  def setup
    @store = Conclave::Store.new(":memory:")
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

  def test_known_agents
    refute @store.known_agent?("b")
    @store.remember_agent("b")
    @store.remember_agent("b")
    @store.remember_agent("a")
    assert @store.known_agent?("b")
    assert_equal %w[a b], @store.known_agents
  end

  def test_common_joined
    refute @store.common_joined?("a")
    @store.mark_common_joined("a")
    @store.mark_common_joined("a")
    assert @store.common_joined?("a")
  end

  def test_remove_after_common_join_sticks
    @store.add_membership("a", "C1")
    @store.mark_common_joined("a")
    @store.remove_membership("a", "C1")
    assert @store.common_joined?("a")
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

  def test_consult_round_trip
    refute @store.consults?("a", "B1")
    @store.consult("a", "U1", "B1")
    @store.consult("a", "U1", "B1")
    assert @store.consults?("a", "B1")
    refute @store.consults?("b", "B1")
    refute @store.consults?("a", "B2")
    assert @store.unconsult("a", "U1")
    refute @store.consults?("a", "B1")
    refute @store.unconsult("a", "U1")
  end

  def test_record_agent_thread_caps_per_agent
    @store.record_agent_thread("b", "C1", "1.0", limit: 2)
    %w[1.0 2.0 3.0].each { |ts| @store.record_agent_thread("a", "C1", ts, limit: 2) }
    refute @store.agent_thread?("a", "C1", "1.0")
    assert @store.agent_thread?("a", "C1", "2.0")
    assert @store.agent_thread?("a", "C1", "3.0")
    refute @store.agent_thread?("a", "C2", "3.0")
    assert @store.agent_thread?("b", "C1", "1.0")
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

  def test_agent_authority_round_trip
    assert_nil @store.agent_authority("a")
    @store.set_agent_authority("a", "UJANE")
    @store.set_agent_authority("b", :none)
    assert_equal "UJANE", @store.agent_authority("a")
    assert_equal :none, @store.agent_authority("b")
    @store.set_agent_authority("a", "UTAD")
    assert_equal "UTAD", @store.agent_authority("a")
  end

  def test_forget_clears_everything
    @store.add_membership("a", "C1")
    @store.add_membership("b", "C1")
    @store.remember_agent("a")
    @store.remember_agent("b")
    @store.mark_common_joined("a")
    @store.authorize("a", "U1")
    @store.authorize("b", "U1")
    @store.enqueue("a", { "x" => 1 }, limit: 5)
    @store.set_agent_authority("a", "U1")
    @store.consult("a", "U2", "B2")
    @store.consult("b", "U2", "B2")
    @store.record_agent_thread("a", "C1", "1.0", limit: 5)
    @store.record_agent_thread("b", "C1", "1.0", limit: 5)
    @store.forget("a")
    refute @store.consults?("a", "B2")
    refute @store.agent_thread?("a", "C1", "1.0")
    assert @store.consults?("b", "B2")
    assert @store.agent_thread?("b", "C1", "1.0")
    assert_nil @store.agent_authority("a")
    assert_empty @store.memberships("a")
    refute @store.known_agent?("a")
    refute @store.common_joined?("a")
    assert_equal %w[b], @store.known_agents
    refute @store.authorized?("a", "U1")
    assert_empty @store.drain("a")
    assert_equal %w[b], @store.members("C1")
    assert @store.authorized?("b", "U1")
  end

  def test_opening_drops_epic_channel_tables
    Dir.mktmpdir do |dir|
      path = File.join(dir, "conclave.db")
      legacy = SQLite3::Database.new(path)
      legacy.execute_batch(<<~SQL)
        CREATE TABLE epic_channels (epic_id INTEGER PRIMARY KEY, channel_id TEXT NOT NULL);
        CREATE TABLE epic_joined (agent TEXT PRIMARY KEY);
        INSERT INTO epic_joined VALUES ('a');
      SQL
      legacy.close
      refute Conclave::Store.new(path).common_joined?("a")
      tables = SQLite3::Database.new(path).execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
      assert_empty tables & %w[epic_channels epic_joined]
    end
  end

  def test_file_db_persists
    Dir.mktmpdir do |dir|
      path = File.join(dir, "conclave.db")
      Conclave::Store.new(path).add_membership("a", "C1")
      assert_equal %w[C1], Conclave::Store.new(path).memberships("a")
    end
  end
end

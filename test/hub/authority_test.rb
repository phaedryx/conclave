# frozen_string_literal: true

require "test_helper"

class AuthorityTest < Minitest::Test
  AGENT = "tad_sc-1"

  def setup
    @store = Conclave::Store.new(":memory:")
    @authority = Conclave::Hub::Authority.new(owner: "UTAD", store: @store)
  end

  def test_combine_equal_values
    assert_equal "UTAD", @authority.combine("UTAD", "UTAD")
    assert_equal "UJANE", @authority.combine("UJANE", "UJANE")
  end

  def test_combine_owner_yields_other_in_both_orders
    assert_equal "UJANE", @authority.combine("UTAD", "UJANE")
    assert_equal "UJANE", @authority.combine("UJANE", "UTAD")
  end

  def test_combine_two_distinct_non_owners_is_none_in_both_orders
    assert_equal :none, @authority.combine("UJANE", "UBOB")
    assert_equal :none, @authority.combine("UBOB", "UJANE")
  end

  def test_combine_nil_is_identity_in_both_orders
    assert_equal "UJANE", @authority.combine(nil, "UJANE")
    assert_equal "UJANE", @authority.combine("UJANE", nil)
    assert_equal "UTAD", @authority.combine(nil, "UTAD")
    assert_equal :none, @authority.combine(nil, :none)
    assert_equal :none, @authority.combine(:none, nil)
  end

  def test_combine_nil_nil_is_nil
    assert_nil @authority.combine(nil, nil)
  end

  def test_combine_none_absorbs_everything_in_both_orders
    assert_equal :none, @authority.combine(:none, "UTAD")
    assert_equal :none, @authority.combine("UTAD", :none)
    assert_equal :none, @authority.combine(:none, "UJANE")
    assert_equal :none, @authority.combine("UJANE", :none)
    assert_equal :none, @authority.combine(:none, :none)
  end

  def test_permits_owner_always
    assert @authority.permits?("UTAD", AGENT)
  end

  def test_permits_none_is_false
    refute @authority.permits?(:none, AGENT)
  end

  def test_permits_nil_is_false
    refute @authority.permits?(nil, AGENT)
  end

  def test_permits_authorized_user_only_after_authorize
    refute @authority.permits?("UJANE", AGENT)
    @store.authorize(AGENT, "UJANE")
    assert @authority.permits?("UJANE", AGENT)
  end

  def test_permits_is_per_agent
    @store.authorize(AGENT, "UJANE")
    refute @authority.permits?("UJANE", "tad_sc-2")
  end

  def test_human_role_owner
    assert_equal :owner, @authority.human_role("UTAD", AGENT)
  end

  def test_human_role_authorized
    @store.authorize(AGENT, "UJANE")
    assert_equal :authorized, @authority.human_role("UJANE", AGENT)
  end

  def test_human_role_outsider_is_nil
    assert_nil @authority.human_role("UOUT", AGENT)
  end

  def test_constructor_rejects_nil_owner
    assert_raises(ArgumentError) { Conclave::Hub::Authority.new(owner: nil, store: @store) }
  end

  def test_constructor_rejects_empty_owner
    assert_raises(ArgumentError) { Conclave::Hub::Authority.new(owner: "", store: @store) }
  end

  def test_constructor_rejects_non_string_owner
    assert_raises(ArgumentError) { Conclave::Hub::Authority.new(owner: :tad, store: @store) }
  end

  def test_human_role_nil_user_is_nil
    assert_nil @authority.human_role(nil, AGENT)
  end

  def test_human_role_none_symbol_is_nil
    assert_nil @authority.human_role(:none, AGENT)
  end

  def test_permits_nil_with_valid_owner_is_false
    refute @authority.permits?(nil, AGENT)
  end
end

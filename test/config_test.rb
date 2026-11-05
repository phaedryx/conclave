# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def test_loads_values_and_defaults
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.yml"), {
        "bot_token" => "xoxb-1", "app_token" => "xapp-1", "owner_user_id" => "U1", "shortcut_token" => "sc"
      }.to_yaml)
      config = Conclave::Config.load(home: dir)
      assert_equal "xoxb-1", config.bot_token
      assert_equal "xapp-1", config.app_token
      assert_equal "U1", config.owner_user_id
      assert_equal "sc", config.shortcut_token
      assert_equal File.join(dir, "hub.sock"), config.socket_path
      assert_equal File.join(dir, "conclave.sqlite3"), config.db_path
      assert_equal 10, config.loop_guard_limit
      assert_equal 50, config.offline_queue_limit
    end
  end

  def test_overrides_limits
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "config.yml"), { "loop_guard_limit" => 3, "offline_queue_limit" => 5 }.to_yaml)
      config = Conclave::Config.load(home: dir)
      assert_equal 3, config.loop_guard_limit
      assert_equal 5, config.offline_queue_limit
      assert_nil config.bot_token
    end
  end

  def test_expands_tilde
    config = Conclave::Config.new({}, home: "~/.conclave-test")
    assert_equal File.join(Dir.home, ".conclave-test"), config.home
  end

  def test_missing_file_names_path
    Dir.mktmpdir do |dir|
      error = assert_raises(Conclave::Config::Error) { Conclave::Config.load(home: dir) }
      assert_includes error.message, File.join(dir, "config.yml")
    end
  end

  def test_nil_limits_use_defaults
    config = Conclave::Config.new({ "loop_guard_limit" => nil, "offline_queue_limit" => nil }, home: "/tmp/x")
    assert_equal 10, config.loop_guard_limit
    assert_equal 50, config.offline_queue_limit
  end
end

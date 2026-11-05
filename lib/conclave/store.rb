# frozen_string_literal: true

require "json"
require "sqlite3"

module Conclave
  # SQLite-backed persistence. Not thread-safe: the hub serializes calls through one Mutex.
  class Store
    BUSY_TIMEOUT_MS = 5000

    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS epic_channels (
        epic_id INTEGER PRIMARY KEY, channel_id TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS memberships (
        id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, channel_id TEXT NOT NULL,
        UNIQUE (agent, channel_id));
      CREATE TABLE IF NOT EXISTS epic_joined (agent TEXT PRIMARY KEY);
      CREATE TABLE IF NOT EXISTS grants (
        id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, user_id TEXT NOT NULL,
        UNIQUE (agent, user_id));
      CREATE TABLE IF NOT EXISTS queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, payload TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS queue_agent_idx ON queue (agent, id);
      CREATE TABLE IF NOT EXISTS last_seen (
        channel_id TEXT PRIMARY KEY, ts TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS post_authority (
        channel_id TEXT NOT NULL, ts TEXT NOT NULL, authority TEXT NOT NULL, PRIMARY KEY (channel_id, ts));
    SQL

    def initialize(path)
      @db = SQLite3::Database.new(path)
      @db.busy_timeout = BUSY_TIMEOUT_MS
      @db.execute("PRAGMA journal_mode = WAL") unless path == ":memory:"
      @db.execute_batch(SCHEMA)
    end

    def epic_channel(epic_id)
      @db.get_first_value("SELECT channel_id FROM epic_channels WHERE epic_id = ?", [epic_id])
    end

    def set_epic_channel(epic_id, channel_id)
      @db.execute("INSERT OR REPLACE INTO epic_channels (epic_id, channel_id) VALUES (?, ?)", [epic_id, channel_id])
    end

    def add_membership(agent, channel_id)
      @db.execute("INSERT OR IGNORE INTO memberships (agent, channel_id) VALUES (?, ?)", [agent, channel_id])
    end

    def remove_membership(agent, channel_id)
      @db.execute("DELETE FROM memberships WHERE agent = ? AND channel_id = ?", [agent, channel_id])
    end

    def memberships(agent)
      @db.execute("SELECT channel_id FROM memberships WHERE agent = ? ORDER BY id", [agent]).flatten
    end

    def members(channel_id)
      @db.execute("SELECT agent FROM memberships WHERE channel_id = ? ORDER BY id", [channel_id]).flatten
    end

    def forget(agent)
      @db.transaction do
        %w[memberships epic_joined grants queue].each do |table|
          @db.execute("DELETE FROM #{table} WHERE agent = ?", [agent])
        end
      end
    end

    def mark_epic_joined(agent)
      @db.execute("INSERT OR IGNORE INTO epic_joined (agent) VALUES (?)", [agent])
    end

    def epic_joined?(agent)
      !@db.get_first_value("SELECT 1 FROM epic_joined WHERE agent = ?", [agent]).nil?
    end

    def authorize(agent, user_id)
      @db.execute("INSERT OR IGNORE INTO grants (agent, user_id) VALUES (?, ?)", [agent, user_id])
    end

    def deauthorize(agent, user_id)
      @db.execute("DELETE FROM grants WHERE agent = ? AND user_id = ?", [agent, user_id])
    end

    def authorized?(agent, user_id)
      !@db.get_first_value("SELECT 1 FROM grants WHERE agent = ? AND user_id = ?", [agent, user_id]).nil?
    end

    def authorized_agents(user_id)
      @db.execute("SELECT agent FROM grants WHERE user_id = ? ORDER BY id", [user_id]).flatten
    end

    def enqueue(agent, payload, limit:)
      @db.transaction do
        @db.execute("INSERT INTO queue (agent, payload) VALUES (?, ?)", [agent, JSON.generate(payload)])
        @db.execute(<<~SQL, [agent, agent, limit])
          DELETE FROM queue WHERE agent = ? AND id NOT IN (
            SELECT id FROM queue WHERE agent = ? ORDER BY id DESC LIMIT ?)
        SQL
      end
    end

    def drain(agent)
      @db.transaction do
        rows = @db.execute("SELECT payload FROM queue WHERE agent = ? ORDER BY id", [agent])
        @db.execute("DELETE FROM queue WHERE agent = ?", [agent])
        rows.map { |(json)| JSON.parse(json) }
      end
    end

    # Authority of an agent post: a Slack user ID String, or :none (stored as "none").
    def record_post_authority(channel_id, ts, authority)
      value = authority.is_a?(String) ? authority : Hub::Authority::NONE.to_s
      @db.execute("INSERT OR REPLACE INTO post_authority (channel_id, ts, authority) VALUES (?, ?, ?)",
                  [channel_id, ts, value])
    end

    # String, :none, or nil when the post is unknown.
    def post_authority(channel_id, ts)
      value = @db.get_first_value("SELECT authority FROM post_authority WHERE channel_id = ? AND ts = ?",
                                  [channel_id, ts])
      value == Hub::Authority::NONE.to_s ? Hub::Authority::NONE : value
    end

    def last_seen(channel_id)
      @db.get_first_value("SELECT ts FROM last_seen WHERE channel_id = ?", [channel_id])
    end

    def set_last_seen(channel_id, ts)
      @db.execute("INSERT OR REPLACE INTO last_seen (channel_id, ts) VALUES (?, ?)", [channel_id, ts])
    end
  end
end

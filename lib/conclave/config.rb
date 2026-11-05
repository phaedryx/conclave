# frozen_string_literal: true

require "yaml"

module Conclave
  class Config
    Error = Class.new(StandardError)

    DEFAULT_HOME = "~/.conclave"

    attr_reader :home, :bot_token, :app_token, :owner_user_id, :shortcut_token, :loop_guard_limit,
                :offline_queue_limit

    def self.load(home: ENV.fetch("CONCLAVE_HOME", DEFAULT_HOME))
      expanded = File.expand_path(home)
      path = File.join(expanded, "config.yml")
      raise Error, "Conclave config not found at #{path}" unless File.file?(path)

      new(YAML.safe_load_file(path) || {}, home: expanded)
    end

    def initialize(values, home:)
      @home = File.expand_path(home)
      @bot_token = values["bot_token"]
      @app_token = values["app_token"]
      @owner_user_id = values["owner_user_id"]
      @shortcut_token = values["shortcut_token"]
      @loop_guard_limit = values["loop_guard_limit"] || 10
      @offline_queue_limit = values["offline_queue_limit"] || 50
    end

    def socket_path
      File.join(home, "hub.sock")
    end

    def db_path
      File.join(home, "conclave.sqlite3")
    end
  end
end

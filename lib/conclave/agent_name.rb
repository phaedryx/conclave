# frozen_string_literal: true

module Conclave
  module AgentName
    NAME_PATTERN = /\A(.*?sc-\d+)/
    STORY_PATTERN = /sc-(\d+)/

    def self.from_worktree(worktree)
      worktree[NAME_PATTERN, 1] || worktree
    end

    def self.story_id(name)
      match = name.match(STORY_PATTERN)
      match && Integer(match[1], 10)
    end
  end
end

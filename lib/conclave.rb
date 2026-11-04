# frozen_string_literal: true

require "mcp"

module Conclave
end

require_relative "conclave/addressing"
require_relative "conclave/agent_name"
require_relative "conclave/config"
require_relative "conclave/permalink"
require_relative "conclave/shortcut/client"
require_relative "conclave/slack/client"
require_relative "conclave/channel/server"
require_relative "conclave/channel/sync_stdio_transport"

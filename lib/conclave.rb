# frozen_string_literal: true

require "mcp"

module Conclave
end

require_relative "conclave/addressing"
require_relative "conclave/agent_name"
require_relative "conclave/config"
require_relative "conclave/hub/authority"
require_relative "conclave/hub/channel_names"
require_relative "conclave/hub/agents"
require_relative "conclave/hub/commands"
require_relative "conclave/hub/epic_channels"
require_relative "conclave/hub/request_check"
require_relative "conclave/hub/thread_filter"
require_relative "conclave/hub/handler"
require_relative "conclave/hub/router"
require_relative "conclave/hub/server"
require_relative "conclave/permalink"
require_relative "conclave/protocol"
require_relative "conclave/store"
require_relative "conclave/shortcut/client"
require_relative "conclave/slack/client"
require_relative "conclave/channel/server"
require_relative "conclave/channel/sync_stdio_transport"

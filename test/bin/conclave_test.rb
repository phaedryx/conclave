# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"

class BinConclaveTest < Minitest::Test
  BIN = File.expand_path("../../bin/conclave", __dir__)

  def test_wrapper_runs_from_any_directory
    Dir.mktmpdir("cvhome") do |home|
      output, status = Bundler.with_unbundled_env do
        Open3.capture2e({ "CONCLAVE_HOME" => home }, BIN, "forget", "x", chdir: Dir.tmpdir)
      end

      assert_predicate status, :success?, output
      assert_includes output, "hub not running"
    end
  end

  # A non-story Atelier workstream loads the same .mcp.json; the server must answer quietly rather than exit.
  def test_channel_without_agent_serves_an_idle_server
    output, status = Bundler.with_unbundled_env do
      Open3.capture2e({ "CONCLAVE_AGENT" => nil, "ATELIER_WORKSTREAM" => "accessibility" }, BIN, "channel",
                      stdin_data: "#{JSON.generate(INITIALIZE)}\n", chdir: Dir.tmpdir)
    end

    assert_predicate status, :success?, output
    result = JSON.parse(output.lines.first)["result"]

    assert_equal "conclave", result.dig("serverInfo", "name")
    assert_nil result.dig("capabilities", "experimental")
  end

  INITIALIZE = {
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } }
  }.freeze
end

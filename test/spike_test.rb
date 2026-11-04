# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "timeout"

class SpikeTest < Minitest::Test
  EXE = File.expand_path("../exe/conclave", __dir__)

  def test_spike_advertises_channel_capability_and_pushes_notification
    messages = run_spike
    init = messages.find { |m| m["id"] == 1 }

    assert_equal({}, init.dig("result", "capabilities", "experimental", "claude/channel"))

    note = messages.find { |m| m["method"] == "notifications/claude/channel" }

    assert note, "no channel notification received"
    assert_equal(
      { "content" => "hello from conclave", "meta" => { "sender" => "spike", "sender_role" => "owner" } },
      note["params"]
    )
  end

  private

  def run_spike
    messages = []
    Open3.popen3("bundle", "exec", EXE, "spike") do |stdin, stdout, _err, wait|
      stdin.puts JSON.generate(initialize_request)
      stdin.puts JSON.generate(jsonrpc: "2.0", method: "notifications/initialized")
      stdin.flush
      Timeout.timeout(6) do
        while (line = stdout.gets)
          messages << JSON.parse(line)
          break if messages.any? { |m| m["method"] == "notifications/claude/channel" }
        end
      end
    rescue Timeout::Error
      nil
    ensure
      Process.kill("TERM", wait.pid)
    end
    messages
  end

  def initialize_request
    { jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } }
  end
end

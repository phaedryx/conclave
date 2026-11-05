# frozen_string_literal: true

require "test_helper"
require "open3"

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
end

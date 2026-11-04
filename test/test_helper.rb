# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "httpx"
require "webmock"
require "httpx/adapters/webmock"
require "webmock/minitest"
require "json"
require "tmpdir"
require "conclave"

SLACK_BASE_URL = "https://slack.com/api"
SHORTCUT_BASE_URL = "https://api.app.shortcut.com/api/v3"

def stub_slack(method, path, response_body: {}, status: 200, query: nil, request_body: nil, headers: nil)
  body = { "ok" => true }.merge(response_body)
  stub = stub_request(method, "#{SLACK_BASE_URL}/#{path}")
  stub = stub.with(query: query) if query
  stub = stub.with(body: request_body) if request_body
  stub = stub.with(headers: headers) if headers
  stub.to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
end

def stub_shortcut(path, response_body:, status: 200)
  stub_request(:get, "#{SHORTCUT_BASE_URL}/#{path}")
    .with(headers: { "Shortcut-Token" => "sc-token" })
    .to_return(status: status, body: response_body.to_json, headers: { "Content-Type" => "application/json" })
end

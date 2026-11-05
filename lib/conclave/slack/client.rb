# frozen_string_literal: true

require "httpx"
require "json"
require "uri"

module Conclave
  module Slack
    class Client
      class Error < StandardError
        # The Slack error code (e.g. "channel_not_found"); nil for HTTP-level failures.
        attr_reader :code

        def initialize(message = nil, code: nil)
          super(message)
          @code = code
        end
      end

      AuthenticationError = Class.new(Error)
      NotFoundError       = Class.new(Error)
      RateLimitError      = Class.new(Error)
      SlackError          = Class.new(Error)

      # sleep_on_rate_limit: false makes a 429 raise RateLimitError at once, for callers holding a lock.
      def initialize(token:, base_url: "https://slack.com/api", sleep_on_rate_limit: true)
        @base_url = base_url
        @sleep_on_rate_limit = sleep_on_rate_limit
        @http = HTTPX.with(
          resolver_class: :system,
          headers: {
            "Authorization" => "Bearer #{token}",
            "Content-Type" => "application/json; charset=utf-8"
          }
        )
      end

      def auth_test
        post("auth.test")
      end

      def post_message(channel:, text:, thread_ts: nil, username: nil, icon_emoji: nil)
        body = { channel: channel, text: text, thread_ts: thread_ts, username: username, icon_emoji: icon_emoji }
        post("chat.postMessage", body.compact)
      end

      def replies(channel:, ts:, limit: 200)
        get("conversations.replies", channel: channel, ts: ts, limit: limit)
      end

      def history(channel:, latest: nil, oldest: nil, inclusive: false, limit: 20)
        get("conversations.history",
            { channel: channel, latest: latest, oldest: oldest, inclusive: inclusive, limit: limit }.compact)
      end

      def create_channel(name:)
        post("conversations.create", name: name, is_private: false)
      end

      def invite(channel:, users:)
        post("conversations.invite", channel: channel, users: Array(users).join(","))
      end

      def join(channel:)
        post("conversations.join", channel: channel)
      end

      def add_reaction(channel:, ts:, name:)
        post("reactions.add", channel: channel, timestamp: ts, name: name)
      end

      def channel_info(channel:)
        get("conversations.info", channel: channel)
      end

      # Must be called on a client built with the app-level (xapp-) token.
      def open_socket_connection
        post("apps.connections.open")["url"]
      end

      def get(path, params = {})
        request { @http.get(build_url(path, params)) }
      end

      def post(path, body = {})
        request { @http.post(build_url(path, {}), json: body) }
      end

      private

      def build_url(path, params)
        url = "#{@base_url}/#{path}"
        url += "?#{URI.encode_www_form(params)}" unless params.empty?
        url
      end

      def request(&)
        response = yield
        raise Error, "HTTP connection error: #{response.error}" if response.is_a?(HTTPX::ErrorResponse)

        response = retry_rate_limited(response, &) if response.status == 429
        handle_response(response)
      end

      def retry_rate_limited(response)
        raise rate_limited("Slack rate limit exceeded") unless @sleep_on_rate_limit

        sleep (response.headers["retry-after"]&.to_i || 1).clamp(1, 30)
        response = yield
        raise rate_limited("Slack rate limit exceeded (retry also failed)") if response.status == 429

        response
      end

      def rate_limited(message) = RateLimitError.new(message, code: "ratelimited")

      def handle_response(response)
        case response.status
        when 200..299
          data = JSON.parse(response.body.to_s)
          handle_slack_error(data["error"]) unless data["ok"]
          data
        when 401
          raise AuthenticationError, "Slack authentication failed. Check your token."
        else
          raise Error, "Slack API error (#{response.status}): #{response.body}"
        end
      end

      def handle_slack_error(error_code)
        case error_code
        when "invalid_auth", "not_authed", "token_revoked"
          raise AuthenticationError.new("Slack authentication error: #{error_code}", code: error_code)
        when "channel_not_found", "user_not_found"
          raise NotFoundError.new("Slack resource not found: #{error_code}", code: error_code)
        else
          raise SlackError.new("Slack API error: #{error_code}", code: error_code)
        end
      end
    end
  end
end

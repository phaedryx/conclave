# frozen_string_literal: true

require "httpx"
require "json"

module Conclave
  module Shortcut
    class Client
      Error = Class.new(StandardError)

      BASE_URL = "https://api.app.shortcut.com/api/v3"

      def initialize(token:)
        @http = HTTPX.with(
          resolver_class: :system,
          headers: { "Shortcut-Token" => token, "Content-Type" => "application/json" }
        )
      end

      # Returns { id:, name: } for the story's epic, or nil when the story has no epic or doesn't exist.
      def epic_for_story(story_id)
        story = fetch("stories/#{story_id}")
        epic_id = story && story["epic_id"]
        return nil unless epic_id

        epic = fetch("epics/#{epic_id}")
        epic && { id: epic["id"], name: epic["name"] }
      end

      private

      def fetch(path)
        response = @http.get("#{BASE_URL}/#{path}")
        raise Error, "Shortcut connection error: #{response.error}" if response.is_a?(HTTPX::ErrorResponse)

        case response.status
        when 200..299 then JSON.parse(response.body.to_s)
        when 404 then nil
        else raise Error, "Shortcut API error (#{response.status}): #{response.body}"
        end
      end
    end
  end
end

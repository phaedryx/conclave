# frozen_string_literal: true

module Conclave
  class Hub
    # Puts the bot in a channel so agents can post there. A public channel is joined; a private one can only be
    # entered by Tad adding the app, so it is checked for membership instead.
    module ChannelJoin
      Private = Class.new(StandardError)
      PRIVATE_CODE = "method_not_supported_for_channel_type"

      # Raises Private for a private channel the app is not in; any other Slack error propagates.
      def self.ensure(slack, channel_id)
        channel = slack.channel_info(channel: channel_id)["channel"] || {}
        if channel["is_private"]
          raise Private, "the Conclave app is not in this private channel" unless channel["is_member"]
        else
          slack.join(channel: channel_id)
        end
        nil
      rescue Slack::Client::Error => e
        raise e.code == PRIVATE_CODE ? Private.new(e.message) : e
      end
    end
  end
end

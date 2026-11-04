# frozen_string_literal: true

module Conclave
  module Hub
    # Authority values are a Slack user ID String, or :none. Authority never passes
    # between agents: it narrows when combined and is checked per agent.
    class Authority
      NONE = :none

      def initialize(owner:, store:)
        @owner = owner
        @store = store
      end

      # Narrowest authority of two. nil is identity, :none absorbs, the owner yields to the other.
      def combine(first, second)
        return second if first.nil?
        return first if second.nil?
        return NONE if [first, second].include?(NONE)
        return first if first == second

        narrower(first, second)
      end

      def permits?(authority, agent)
        authority == @owner || (authority.is_a?(String) && @store.authorized?(agent, authority))
      end

      def human_role(user_id, agent)
        return :owner if user_id == @owner

        :authorized if @store.authorized?(agent, user_id)
      end

      private

      def narrower(first, second)
        return second if first == @owner
        return first if second == @owner

        NONE
      end
    end
  end
end

# frozen_string_literal: true

module Conclave
  module Hub
    # Validates a parsed request before the handler echoes or serializes any of it.
    module RequestCheck
      ID_TYPES = [NilClass, String, Integer].freeze

      # A Hash with an absent, String or Integer id and only valid UTF-8 text.
      def self.well_formed?(request)
        request.is_a?(Hash) && ID_TYPES.any? { |type| request["id"].is_a?(type) } && valid_text?(request)
      end

      def self.valid_text?(value)
        case value
        when String then value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        when Hash then value.all? { |key, nested| valid_text?(key) && valid_text?(nested) }
        when Array then value.all? { |nested| valid_text?(nested) }
        else true
        end
      end
    end
  end
end

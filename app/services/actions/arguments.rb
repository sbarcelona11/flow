# frozen_string_literal: true

module Actions
  module Arguments
    KEY = /[a-z0-9_]+(?:\.[a-z0-9_]+)*/
    PLACEHOLDER = /\{\{context:(#{KEY})\}\}/
    WHOLE = /\A#{PLACEHOLDER}\z/

    class Missing < StandardError
      attr_reader :key

      def initialize(key)
        @key = key
        super("the run's context has no value for #{key}")
      end
    end

    module_function

    def resolve(arguments, shared_context:)
      substitute(arguments, shared_context.to_h)
    end

    def substitute(value, context)
      case value
      when Hash then value.transform_values { |v| substitute(v, context) }
      when Array then value.map { |v| substitute(v, context) }
      when String then substitute_string(value, context)
      else value
      end
    end

    def substitute_string(text, context)
      whole = text.match(WHOLE)
      return lookup(context, whole[1]) if whole

      text.gsub(PLACEHOLDER) { inline(lookup(context, Regexp.last_match(1))) }
    end

    def lookup(context, key)
      key.split(".").reduce(context) do |node, part|
        raise Missing, key unless node.is_a?(Hash) && node.key?(part)

        node[part]
      end
    end

    def inline(value)
      value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s
    end

    private_class_method :substitute, :substitute_string, :lookup, :inline
  end
end

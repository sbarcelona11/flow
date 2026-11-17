# frozen_string_literal: true

module Actions
  module Arguments
    KEY = /[a-z0-9_]+(?:\.[a-z0-9_]+)*/
    PLACEHOLDER = /\{\{context:(#{KEY})\}\}/
    WHOLE = /\A#{PLACEHOLDER}\z/
    OUTPUT = /\{\{output:[^{}\n]+?\}\}/
    TOKEN = Regexp.union(PLACEHOLDER, OUTPUT)

    class Missing < StandardError
      attr_reader :key

      def initialize(key)
        @key = key
        super("the run's context has no value for #{key}")
      end
    end

    # A `{{output:…}}` that can't give its value; `ref.id` is nil when the token itself can't be read.
    class Unavailable < StandardError
      attr_reader :ref, :reason

      def initialize(ref, reason)
        @ref = ref
        @reason = reason
        super(reason)
      end
    end

    module_function

    # `outputs` is OutputInputs.load's result. Whatever a placeholder resolves to is data and is never scanned again, so
    # one pass handles both kinds of placeholder.
    def resolve(arguments, shared_context:, outputs: {})
      substitute(arguments, shared_context.to_h, outputs)
    end

    def substitute(value, context, outputs)
      case value
      when Hash then value.transform_values { |v| substitute(v, context, outputs) }
      when Array then value.map { |v| substitute(v, context, outputs) }
      when String then substitute_string(value, context, outputs)
      else value
      end
    end

    def substitute_string(text, context, outputs)
      whole = text.match(WHOLE)
      return lookup(context, whole[1]) if whole

      refs = text.include?("{{output:") ? InstructionReferences.scan(text).select { |ref| ref.type == "output" } : []
      return whole_output(refs.first, outputs) if refs.one? && refs.first.text == text

      resolved = text.gsub(TOKEN) { inline_token(Regexp.last_match, context, outputs) }
      return resolved if refs.empty?

      limit = Step::ACTION_ARGUMENT_STRING_MAX_BYTES
      raise Unavailable.new(refs.first, "the text it is part of would be over #{limit / 1.kilobyte} KB") if resolved.bytesize > limit

      resolved
    end

    def inline_token(match, context, outputs)
      return inline(lookup(context, match[1])) if match[1]

      ref = InstructionReferences.scan(match[0]).first
      text = output_text(ref, outputs)
      json?(ref) ? JSON.generate(parse_json(ref, text)) : text
    end

    def whole_output(ref, outputs)
      text = output_text(ref, outputs)
      json?(ref) ? parse_json(ref, text) : text
    end

    def output_text(ref, outputs)
      raise Unavailable.new(ref, "the reference can't be read") unless ref.valid?

      loaded = outputs[OutputInputs.key(ref)] || raise(Unavailable.new(ref, "it was not loaded"))
      raise Unavailable.new(ref, loaded.reason) if loaded.reason

      loaded.text
    end

    def json?(ref) = ref.name.end_with?(".json")

    def parse_json(ref, text)
      value = JSON.parse(text)
      raise Unavailable.new(ref, "the file has a number that is out of range") unless finite?(value)

      value
    rescue JSON::NestingError
      raise Unavailable.new(ref, "the file is nested too deeply")
    rescue JSON::JSONError
      raise Unavailable.new(ref, "the file isn't valid JSON")
    end

    def finite?(value)
      case value
      when Float then value.finite?
      when Hash then value.each_value.all? { |item| finite?(item) }
      when Array then value.all? { |item| finite?(item) }
      else true
      end
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

    private_class_method :substitute, :substitute_string, :inline_token, :whole_output, :output_text, :json?, :parse_json, :finite?,
                         :lookup, :inline
  end
end

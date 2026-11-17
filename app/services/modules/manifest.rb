# frozen_string_literal: true

module Modules
  # A module manifest is data a project member (later a marketplace publisher) writes, so everything here treats it as
  # untrusted: bounded before and while parsing, validated against config/modules/module.v1.json, and never evaluated.
  class Manifest
    class Invalid < StandardError; end

    MAX_BYTES = 256.kilobytes
    MAX_DEPTH = 32
    NODE_BUDGET = 10_000
    MAX_CONFIG_BYTES = 16.kilobytes
    MAX_MANDATE_BYTES = 8.kilobytes
    MAX_ERRORS = 5
    SCHEMA_PATH = Rails.root.join("config/modules/module.v1.json")
    KINDS = %w[type capability block].freeze
    EXECUTORS = %w[action agent control].freeze
    REF = %r{\A(?<namespace>[a-z0-9]+(?:-[a-z0-9]+)*)/(?<slug>[a-z0-9]+(?:-[a-z0-9]+)*)@(?<version>[1-9]\d*)\z}
    LIST_REF = /\Alist<(?<ref>[^<>]+)>\z/
    CREDENTIAL_NAME = /(key|token|secret|password|passwd|credential)s?\z/i
    CREDENTIAL_VALUE = %r{
      \A(?:sk|pk|rk|ghp|gho|ghs|xox[abprs])[-_][A-Za-z0-9_-]{12,}\z |
      \AAKIA[0-9A-Z]{12,}\z | \AAIza[0-9A-Za-z_-]{20,}\z |
      \A(?:Bearer|Basic)\s+\S{8,} | \Aeyj[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\. |
      -----BEGIN | ://[^/\s:@]+:[^/\s@]+@
    }x
    ATTRIBUTES = %w[kind namespace slug version label description schema input output executor ports config uses
                    effect agent mandate control].freeze

    TOO_LARGE = "This manifest is larger than 256 KB."
    TOO_DEEP = "This manifest nests deeper than #{MAX_DEPTH} levels."
    TOO_MANY_NODES = "This manifest has more than #{NODE_BUDGET} values."
    ALIASES = "This manifest uses YAML aliases (*name), which are not accepted."

    class << self
      def parse(text)
        from_hash(decode(text))
      end

      def from_hash(data)
        raise Invalid, "The manifest must be an object." unless data.is_a?(Hash)

        data = data.deep_stringify_keys
        raise Invalid, TOO_DEEP if SchemaHygiene.depth(data) > MAX_DEPTH + 1
        raise Invalid, TOO_LARGE if JSON.generate(data).bytesize > MAX_BYTES
        raise Invalid, TOO_MANY_NODES if node_count(data) > NODE_BUDGET

        validate_structure!(data)
        validate_semantics!(data)
        new(data)
      end

      def split_ref(ref)
        match = REF.match(ref.to_s)
        match && [ match[:namespace], match[:slug], match[:version].to_i ]
      end

      def unwrap_list(ref)
        LIST_REF.match(ref.to_s)&.[](:ref) || ref.to_s
      end

      private

      def decode(text)
        text = text.to_s
        raise Invalid, TOO_LARGE if text.bytesize > MAX_BYTES

        text = text.dup.force_encoding(Encoding::UTF_8)
        raise Invalid, "This manifest is not UTF-8 text." unless text.valid_encoding?

        text.lstrip.start_with?("{") ? decode_json(text) : decode_yaml(text)
      end

      def decode_json(text)
        JSON.parse(text, max_nesting: MAX_DEPTH)
      rescue JSON::NestingError
        raise Invalid, TOO_DEEP
      rescue JSON::ParserError
        raise Invalid, "This manifest is not valid JSON or YAML."
      end

      def decode_yaml(text)
        walk_yaml(Psych.parse(text))
        plain(Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false))
      rescue Psych::SyntaxError => e
        raise Invalid, "This manifest is not valid JSON or YAML (line #{e.line}, column #{e.column})."
      rescue Psych::DisallowedClass
        raise Invalid, "This manifest uses a YAML type that is not accepted; only plain strings, numbers, " \
                       "booleans, lists and maps are allowed."
      end

      def walk_yaml(tree)
        stack = tree ? [ [ tree, 0 ] ] : []
        count = 0
        while (entry = stack.pop)
          node, depth = entry
          raise Invalid, ALIASES if node.is_a?(Psych::Nodes::Alias)
          raise Invalid, TOO_DEEP if depth > MAX_DEPTH
          raise Invalid, TOO_MANY_NODES if (count += 1) > NODE_BUDGET

          Array(node.children).each { |child| stack << [ child, depth + 1 ] }
        end
      end

      def plain(value)
        case value
        when Hash then value.to_h { |key, child| [ key.to_s, plain(child) ] }
        when Array then value.map { |child| plain(child) }
        else value
        end
      end

      def node_count(root)
        count = 0
        stack = [ root ]
        while (node = stack.pop)
          count += 1
          return count if count > NODE_BUDGET

          case node
          when Hash then stack.concat(node.values)
          when Array then stack.concat(node)
          end
        end
        count
      end

      def schema_document
        @schema_document ||= JSON.parse(SCHEMA_PATH.read).freeze
      end

      def definition_for(data)
        kind = data["kind"]
        raise Invalid, "kind must be one of: #{KINDS.join(', ')}." unless KINDS.include?(kind)
        return kind unless kind == "block"

        executor = data["executor"]
        raise Invalid, "executor must be one of: #{EXECUTORS.join(', ')}." unless EXECUTORS.include?(executor)

        "block_#{executor}"
      end

      def validate_structure!(data)
        definition = definition_for(data)
        schema = JSONSchemer.schema(schema_document.merge("oneOf" => nil).compact.merge("$ref" => "#/$defs/#{definition}"),
                                    ref_resolver: ->(uri) { raise Invalid, "Remote references are not accepted: #{uri}" })
        problems = schema.validate(data).first(MAX_ERRORS).map do |error|
          pointer = error["data_pointer"].presence
          "#{pointer ? pointer.delete_prefix('/').tr('/', '.') : 'manifest'}: #{error['error']}"
        end
        raise Invalid, problems.join("; ") if problems.any?
      end

      def validate_semantics!(data)
        case data["kind"]
        when "type" then check_schema!("schema", data["schema"])
        when "block" then validate_block!(data)
        end
        return unless data["description"].to_s.match?(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/)

        raise Invalid, "description must be plain text."
      end

      def validate_block!(data)
        config = data["config"]
        if config
          raise Invalid, "config is larger than #{MAX_CONFIG_BYTES / 1024} KB." if JSON.generate(config).bytesize > MAX_CONFIG_BYTES

          check_schema!("config", config)
          credential = credential_default(config)
          raise Invalid, "config must not carry credentials (found one at #{credential})." if credential
        end
        if data["mandate"] && data["mandate"].bytesize > MAX_MANDATE_BYTES
          raise Invalid, "mandate is larger than #{MAX_MANDATE_BYTES / 1024} KB."
        end

        runtime = data.dig("agent", "runtime")
        return if runtime.nil? || Step::SUPPORTED_AGENT_RUNTIMES.include?(runtime)

        raise Invalid, "agent.runtime must be one of: #{Step::SUPPORTED_AGENT_RUNTIMES.join(', ')}."
      end

      def check_schema!(name, schema)
        problems = SchemaHygiene.errors_for(schema)
        raise Invalid, "#{name} #{problems.first}." if problems.any?
      end

      def credential_default(schema, path = "config")
        return unless schema.is_a?(Hash)

        schema.each do |key, value|
          here = "#{path}.#{key}"
          if key == "default" && credential_value?(value)
            return here
          elsif key == "properties" && value.is_a?(Hash)
            value.each do |name, sub|
              default = sub.is_a?(Hash) ? sub["default"] : nil
              return "#{here}.#{name}.default" if name.match?(CREDENTIAL_NAME) && default.is_a?(String) && default.present?
            end
          end
          found = value.is_a?(Hash) ? credential_default(value, here) : array_credential(value, here)
          return found if found
        end
        nil
      end

      def array_credential(value, path)
        return unless value.is_a?(Array)

        value.each_with_index do |item, index|
          found = credential_default(item, "#{path}[#{index}]")
          return found if found
        end
        nil
      end

      def credential_value?(value)
        case value
        when String then value.match?(CREDENTIAL_VALUE)
        when Hash then value.each_value.any? { |v| credential_value?(v) }
        when Array then value.any? { |v| credential_value?(v) }
        else false
        end
      end
    end

    attr_reader :data

    def initialize(data)
      @data = data.freeze
    end

    ATTRIBUTES.each { |name| define_method(name) { data[name] } }

    def key = "#{namespace}/#{slug}@#{version}"

    def to_h = data

    def canonical_json = JSON.generate(canonicalize(data))

    def digest = Digest::SHA256.hexdigest(canonical_json)

    private

    def canonicalize(value)
      case value
      when Hash then value.sort_by { |key, _| key }.to_h { |key, child| [ key, canonicalize(child) ] }
      when Array then value.map { |child| canonicalize(child) }
      else value
      end
    end
  end
end

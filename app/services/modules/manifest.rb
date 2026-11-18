# frozen_string_literal: true

module Modules
  # A module manifest is data a project member (later a marketplace publisher) writes, so everything here treats it as
  # untrusted: bounded before and while parsing, validated against config/modules/module.v1.json, and never evaluated.
  class Manifest
    class Invalid < StandardError
      def initialize(message = nil)
        super(Manifest.sanitize(message).presence || self.class.name)
      end
    end

    MAX_BYTES = 256.kilobytes
    MAX_DEPTH = 32
    NODE_BUDGET = 10_000
    MAX_CONFIG_BYTES = 16.kilobytes
    MAX_MANDATE_BYTES = 8.kilobytes
    MAX_ERRORS = 5
    SCHEMA_PATH = Rails.root.join("config/modules/module.v1.json")
    KINDS = %w[type capability block].freeze
    EXECUTORS = %w[action agent control].freeze
    REF = %r{\A(?<namespace>[a-z0-9]+(?:-[a-z0-9]+)*)/(?<slug>[a-z0-9]+(?:[.-][a-z0-9]+)*)@(?<version>[1-9]\d{0,9})\z}
    LIST_REF = /\Alist<(?<ref>[^<>]+)>\z/
    CREDENTIAL_NAME = /(key|token|secret|password|passwd|credential)s?\z/i
    CREDENTIAL_VALUE = %r{
      \A(?:sk|pk|rk|ghp|gho|ghs|xox[abprs])[-_][A-Za-z0-9_-]{12,}\z |
      \AAKIA[0-9A-Z]{12,}\z | \AAIza[0-9A-Za-z_-]{20,}\z |
      \A(?:Bearer|Basic)\s+\S{8,} | \Aeyj[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\. |
      -----BEGIN | ://[^/\s:@]+:[^/\s@]+@
    }x
    MAX_VERSION = 2_147_483_647
    MAX_MESSAGE = 1_000
    MESSAGE_HEAD = 300
    UNSAFE_TEXT = /[\u0000\u2028\u2029\u202A-\u202E\u2066-\u2069]/
    NAME_KEYED = %w[properties patternProperties dependentSchemas dependentRequired definitions].freeze
    DATA_KEYS = %w[default const enum examples].freeze
    SEGMENT_MAX = 64
    FORMAT_VERSION = 1
    NAME = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
    CAPABILITY_SLUG = /\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/
    PORT_NAME = /\A[a-z][a-z0-9_]{0,63}\z/
    TRANSPORT = /\A[a-z][a-z0-9_]{0,31}\z/
    LINE_TEXT_FORBIDDEN = /[[:cntrl:]]/
    BLOCK_TEXT_FORBIDDEN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/
    FORBIDDEN_SCHEMA_KEYS = (SchemaHygiene::FORBIDDEN_KEYS + %w[$schema $id $anchor $recursiveRef $recursiveAnchor $vocabulary]).freeze
    CREDENTIAL_KEYS = %w[default const enum examples].freeze
    ATTRIBUTES = %w[format_version kind namespace slug version label description schema input output executor ports config
                    uses effect cost_cents agent mandate control].freeze

    TOO_LARGE = "This manifest is larger than 256 KB."
    TOO_DEEP = "This manifest nests deeper than #{MAX_DEPTH} levels."
    TOO_MANY_NODES = "This manifest has more than #{NODE_BUDGET} values."
    ALIASES = "This manifest uses YAML aliases (*name), which are not accepted."

    class << self
      def sanitize(text)
        string = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
        string = string.gsub(/[[:cntrl:]<>&]/) { |char| format("\\u%04x", char.ord) }
        return string if string.length <= MAX_MESSAGE

        "#{string[0, MESSAGE_HEAD]}...#{string[-(MAX_MESSAGE - MESSAGE_HEAD - 3)..]}"
      rescue StandardError
        ""
      end

      def parse(text)
        from_hash(decode(text))
      rescue Invalid
        raise
      rescue StandardError
        raise Invalid, "This manifest could not be read."
      end

      def from_hash(data)
        raise Invalid, "The manifest must be an object." unless data.is_a?(Hash)

        data = data.deep_stringify_keys
        raise Invalid, TOO_DEEP if SchemaHygiene.depth(data) > MAX_DEPTH + 1

        scan!(data)
        raise Invalid, TOO_LARGE if JSON.generate(data).bytesize > MAX_BYTES

        check_format_version!(data)
        validate_structure!(data)
        validate_semantics!(data)
        new(data)
      rescue Invalid
        raise
      rescue StandardError
        raise Invalid, "This manifest could not be processed."
      end

      def split_ref(ref)
        match = REF.match(ref.to_s)
        match && [ match[:namespace], match[:slug], match[:version].to_i ]
      end

      def unwrap_list(ref)
        LIST_REF.match(ref.to_s)&.[](:ref) || ref.to_s
      end

      def type_ref?(ref)
        match = REF.match(unwrap_list(ref))
        !match.nil? && match[:slug].match?(NAME) && match[:version].to_i <= MAX_VERSION
      end

      def capability_ref?(ref)
        match = REF.match(ref.to_s)
        !match.nil? && match[:version].to_i <= MAX_VERSION
      end

      private

      def decode(text)
        text = text.to_s
        raise Invalid, TOO_LARGE if text.bytesize > MAX_BYTES

        text = text.dup.force_encoding(Encoding::UTF_8)
        raise Invalid, "This manifest is not UTF-8 text." unless text.valid_encoding?

        text = text.delete_prefix("﻿")
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
        stream = Psych.parse_stream(text)
        raise Invalid, "This manifest has more than one YAML document." if stream.children.size > 1

        walk_yaml(stream)
        plain(Psych.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false))
      rescue Psych::SyntaxError => e
        raise Invalid, "This manifest is not valid JSON or YAML (line #{e.line}, column #{e.column})."
      rescue Psych::DisallowedClass
        raise Invalid, "This manifest uses a YAML type that is not accepted; only plain strings, numbers, " \
                       "booleans, lists and maps are allowed."
      end

      def walk_yaml(tree)
        stack = [ [ tree, -2 ] ]
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

      def scan!(root)
        count = 0
        stack = [ root ]
        while (node = stack.pop)
          raise Invalid, TOO_MANY_NODES if (count += 1) > NODE_BUDGET

          case node
          when Hash
            node.each_key { |key| check_text!(key) }
            stack.concat(node.values)
          when Array then stack.concat(node)
          when Float then raise Invalid, "This manifest has a number that is not finite." unless node.finite?
          when String then check_text!(node)
          end
        end
      end

      def check_text!(string)
        raise Invalid, "This manifest has text that is not valid UTF-8." if string.encoding == Encoding::BINARY || !string.valid_encoding?
        raise Invalid, "This manifest has text with a NUL, line-separator or bidirectional control character." if string.match?(UNSAFE_TEXT)
      end

      def check_format_version!(data)
        return unless data.key?("format_version")

        version = data["format_version"]
        raise Invalid, "Unsupported manifest format version #{version.inspect}." unless version.is_a?(Integer) && version == FORMAT_VERSION
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
                                    regexp_resolver: "ecma",
                                    ref_resolver: ->(uri) { raise Invalid, "Remote references are not accepted: #{uri}" })
        problems = schema.validate(data).first(MAX_ERRORS).map do |error|
          pointer = error["data_pointer"].to_s.split("/").reject(&:empty?).map { |segment| segment.truncate(SEGMENT_MAX) }
          "#{pointer.empty? ? 'manifest' : pointer.join('.')}: #{error['error']}"
        end
        raise Invalid, problems.join("; ") if problems.any?
      end

      def validate_semantics!(data)
        check_identifiers!(data)
        check_free_text!(data)
        case data["kind"]
        when "type" then check_schema!("schema", data["schema"])
        when "block" then validate_block!(data)
        end
      end

      def check_identifiers!(data)
        slug_format = data["kind"] == "capability" ? CAPABILITY_SLUG : NAME
        raise Invalid, "namespace is not a valid name." unless data["namespace"].match?(NAME)
        raise Invalid, "slug is not a valid name." unless data["slug"].match?(slug_format)
        raise Invalid, "version must be a whole number." unless data["version"].is_a?(Integer)
        raise Invalid, "version must be at most #{MAX_VERSION}." unless data["version"] <= MAX_VERSION

        refs = (data["ports"] || {}).flat_map { |side, ports| ports.map { |name, ref| [ "ports.#{side}.#{name}", name, ref ] } }
        refs += %w[input output].filter_map { |side| data[side] && [ side, "x", data[side] ] }
        refs.each do |where, name, ref|
          raise Invalid, "#{where} is not a valid port name." unless name.match?(PORT_NAME) || name == "x"
          raise Invalid, "#{where} is not a valid type reference." unless type_ref?(ref)
        end
        capability = data.dig("uses", "capability")
        raise Invalid, "uses.capability is not a valid reference." if capability && !capability_ref?(capability)
        transport = data.dig("uses", "transport")
        raise Invalid, "uses.transport is not a valid name." if transport && !transport.match?(TRANSPORT)
      end

      def check_free_text!(data)
        { "label" => data["label"], "agent.persona" => data.dig("agent", "persona") }.each do |name, text|
          raise Invalid, "#{name} must be plain text." if text.to_s.match?(LINE_TEXT_FORBIDDEN)
        end
        { "description" => data["description"], "mandate" => data["mandate"] }.each do |name, text|
          raise Invalid, "#{name} must be plain text." if text.to_s.match?(BLOCK_TEXT_FORBIDDEN)
        end
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
        keyword = forbidden_keyword(schema)
        raise Invalid, "#{name} uses unsupported keyword #{keyword}." if keyword

        problem = regex_problem(schema)
        raise Invalid, "#{name} #{problem}." if problem

        problems = SchemaHygiene.errors_for(schema)
        raise Invalid, "#{name} #{problems.first}." if problems.any?
      end

      def forbidden_keyword(root)
        stack = [ root ]
        while (node = stack.pop)
          case node
          when Hash
            node.each do |key, value|
              return key if FORBIDDEN_SCHEMA_KEYS.include?(key)
              next if DATA_KEYS.include?(key)

              if NAME_KEYED.include?(key) && value.is_a?(Hash)
                stack.concat(value.values)
              else
                stack << value
              end
            end
          when Array then stack.concat(node)
          end
        end
        nil
      end

      def regex_problem(root)
        stack = [ root ]
        while (node = stack.pop)
          case node
          when Hash
            node.each do |key, value|
              problem = regex_keyword_problem(key, value)
              return problem if problem
            end
            stack.concat(node.values)
          when Array then stack.concat(node)
          end
        end
        nil
      end

      def regex_keyword_problem(key, value)
        return "uses format regex, which is not accepted" if key == "format" && value == "regex"

        patterns = case key
        when "pattern" then [ value ]
        when "patternProperties" then value.is_a?(Hash) ? value.keys : []
        else []
        end
        patterns.grep(String).each do |pattern|
          reason = pattern_problem(pattern)
          return "has a pattern that is not accepted (#{reason})" if reason
        end
        nil
      end

      def pattern_problem(pattern)
        regexp = Regexp.new(JSONSchemer::EcmaRegexp.ruby_equivalent(pattern))
        Regexp.linear_time?(regexp) ? nil : "it can take unbounded time to match"
      rescue StandardError
        "it is not a valid regular expression"
      end

      def credential_default(schema, path = "config")
        return unless schema.is_a?(Hash)

        schema.each do |key, value|
          here = "#{path}.#{key}"
          if CREDENTIAL_KEYS.include?(key) && credential_value?(value)
            return here
          elsif key == "properties" && value.is_a?(Hash)
            value.each do |name, sub|
              next unless name.match?(CREDENTIAL_NAME) && sub.is_a?(Hash)

              fixed = sub.values_at("default", "const").find { |candidate| candidate.is_a?(String) && candidate.present? }
              return "#{here}.#{name}" if fixed
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
      @data = deep_freeze(data.deep_dup)
    end

    ATTRIBUTES.each { |name| define_method(name) { data[name] } }

    def key = "#{namespace}/#{slug}@#{version}"

    def to_h = data

    def canonical_json = JSON.generate(canonicalize(data))

    def digest = Digest::SHA256.hexdigest(canonical_json)

    private

    def deep_freeze(value)
      case value
      when Hash then value.each { |key, child| key.freeze && deep_freeze(child) }
      when Array then value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def canonicalize(value)
      case value
      when Hash then value.sort_by { |key, _| key }.to_h { |key, child| [ key, canonicalize(child) ] }
      when Array then value.map { |child| canonicalize(child) }
      else value
      end
    end
  end
end

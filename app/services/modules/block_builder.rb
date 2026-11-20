# frozen_string_literal: true

module Modules
  # Turns one REST operation and a few choices into a block manifest, so nobody writes YAML to get a block. The operation's
  # input schema is imported or agent-written, so every property is made to pass Modules::Manifest (the single parser)
  # before it is copied: what it would refuse is dropped, with one warning per property, instead of failing the wizard.
  class BlockBuilder
    class Invalid < StandardError; end

    Result = Data.define(:manifest, :warnings)

    DEFAULT_NAMESPACE = "local"
    DATA_KEYWORDS = %w[default const enum examples].freeze
    CONFIG_BUDGET = Manifest::MAX_CONFIG_BYTES - 512
    NODE_LIMIT = Manifest::NODE_BUDGET / 2
    STAGES = %i[unsafe credential data].freeze

    class << self
      def from_operation(project:, operation:, label:, description: nil, settings: nil, effect: nil, namespace: DEFAULT_NAMESPACE, slug: nil)
        new(project, operation, namespace).build(label: label, description: description, settings: settings, effect: effect, slug: slug)
      end
    end

    def initialize(project, operation, namespace)
      raise Invalid, "the operation belongs to another project" unless operation.api_connector.scope == project
      raise Invalid, "namespace #{namespace.inspect} is reserved" if namespace.to_s == Registry::BUILTIN_NAMESPACE

      @project = project
      @operation = operation
      @connector = operation.api_connector
      @namespace = namespace.to_s
      @warnings = []
    end

    def build(label:, description:, settings:, effect:, slug:)
      slug ||= pick_slug
      manifest = {
        "kind" => "block", "namespace" => @namespace, "slug" => slug, "version" => next_version(slug),
        "label" => label.to_s, "executor" => "action",
        "uses" => { "transport" => "rest", "connection" => @connector.name, "operation" => @operation.name },
        "ports" => { "in" => {}, "out" => { "result" => "aixle/record@1" } },
        "effect" => raised_effect(effect)
      }
      text = clean_text(description.presence || @operation.description.presence || @operation.summary)
      manifest["description"] = text.truncate(2000, omission: "") if text.present?
      config = build_config(settings)
      manifest["config"] = config if config
      Result.new(manifest: finish(manifest), warnings: @warnings)
    end

    private

    def finish(manifest)
      Manifest.from_hash(manifest).to_h.deep_dup
    rescue Manifest::Invalid
      raise unless manifest.key?("config")

      @warnings << "The settings were left out because the block format does not accept them."
      Manifest.from_hash(manifest.except("config")).to_h.deep_dup
    end

    def raised_effect(requested)
      return @operation.effect if requested.blank?
      raise Invalid, "effect must be one of #{Step::ACTION_EFFECTS.join(', ')}" unless Step::ACTION_EFFECTS.include?(requested)

      Actions::Effect.at_least?(requested, @operation.effect) ? requested : @operation.effect
    end

    def operation_slug = tidy(@operation.name.tr("_", "-"))

    def pick_slug
      plain = operation_slug
      return plain unless taken_for_other_operation?(plain)

      prefix = tidy(@connector.name.to_s.downcase.gsub(/[^a-z0-9]+/, "-"))
      prefix = "connector-#{@connector.id}" if prefix.blank?
      candidate = tidy("#{prefix}-#{plain}")
      return candidate unless taken_for_other_operation?(candidate)

      tidy("connector-#{@connector.id}-#{plain}")
    end

    def tidy(text) = text.gsub(/-+/, "-")[0, 64].gsub(/\A-+|-+\z/, "")

    def taken_for_other_operation?(slug)
      definitions(slug).any? do |definition|
        uses = definition.manifest["uses"].to_h
        uses["connection"] != @connector.name || uses["operation"] != @operation.name
      end
    end

    def definitions(slug)
      ModuleDefinition.where(scope_type: "Project", scope_id: @project.id, kind: "block", namespace: @namespace, slug: slug)
    end

    def next_version(slug) = definitions(slug).maximum(:version).to_i + 1

    def clean_text(text) = text.to_s.gsub(Manifest::BLOCK_TEXT_FORBIDDEN, "").gsub(Manifest::UNSAFE_TEXT, "").strip

    def build_config(settings)
      groups = @operation.input_schema.is_a?(Hash) ? @operation.input_schema["properties"] : nil
      return unless groups.is_a?(Hash)

      wanted = settings.nil? ? nil : Array(settings).map(&:to_s)
      check_settings!(groups, wanted)
      kept = groups.filter_map { |group, group_schema| exposed_group(group, group_schema, wanted) }.to_h
      kept = fit_budget(kept)
      return if kept.empty?

      { "type" => "object", "properties" => kept }
    end

    def check_settings!(groups, wanted)
      return unless wanted

      known = groups.flat_map { |group, schema| leaves(schema).keys.flat_map { |leaf| [ leaf, "#{group}.#{leaf}" ] } }
      unknown = wanted - known
      raise Invalid, "unknown setting #{unknown.first.to_s.inspect[0, 80]}: it is not an argument of #{@operation.name}" if unknown.any?
    end

    def leaves(group_schema)
      properties = group_schema.is_a?(Hash) ? group_schema["properties"] : nil
      properties.is_a?(Hash) ? properties : {}
    end

    def exposed_group(group, group_schema, wanted)
      unless ApiOperation::ARGUMENT_GROUPS.include?(group)
        @warnings << "The argument group #{group.to_s.inspect[0, 40]} was left out: only path, query and body are used."
        return
      end

      properties = leaves(group_schema).filter_map do |name, schema|
        next if wanted && (wanted & [ name, "#{group}.#{name}" ]).empty?

        safe = safe_property(group, name, schema)
        [ name, safe ] if safe
      end.to_h
      return if properties.empty?

      group_config = { "type" => "object", "properties" => properties }
      required = Array(group_schema["required"]).map(&:to_s) & properties.keys
      group_config["required"] = required if required.any?
      [ group, group_config ]
    end

    def fit_budget(groups)
      dropped = 0
      while over_budget?(groups)
        group, config = groups.to_a.last
        name = config["properties"].keys.last
        config["properties"].delete(name)
        config["required"]&.delete(name)
        groups.delete(group) if config["properties"].empty?
        dropped += 1
      end
      @warnings << "#{dropped} argument(s) were left out because the block's settings are too large." if dropped.positive?
      groups
    end

    def over_budget?(groups)
      return false if groups.empty?

      JSON.generate(groups).bytesize > CONFIG_BUDGET || node_count(groups) > NODE_LIMIT
    end

    def node_count(root)
      count = 0
      stack = [ root ]
      while (node = stack.pop)
        count += 1
        stack.concat(node.is_a?(Hash) ? node.values : node) if node.is_a?(Hash) || node.is_a?(Array)
      end
      count
    end

    def safe_property(group, name, schema)
      path = "#{group}.#{name}"
      candidate = scrub(schema.deep_dup)
      return candidate if acceptable?(name, candidate)

      @removed = []
      STAGES.each do |stage|
        candidate = strip(candidate, stage, name, top: true)
        next unless acceptable?(name, candidate)

        @warnings << "#{path}: left out #{@removed.uniq.join(', ')} because the block format does not accept it."
        return candidate
      end

      @warnings << "#{path}: left out because the block format does not accept it."
      nil
    end

    def acceptable?(name, schema)
      probe = { "kind" => "block", "namespace" => "probe", "slug" => "probe", "version" => 1, "label" => "Probe", "executor" => "action",
                "uses" => { "transport" => "rest", "connection" => "probe", "operation" => "probe" },
                "ports" => { "in" => {}, "out" => {} },
                "config" => { "type" => "object", "properties" => { "query" => { "type" => "object", "properties" => { name => schema } } } } }
      Manifest.from_hash(probe)
      true
    rescue Manifest::Invalid
      false
    end

    def scrub(value)
      case value
      when Hash then value.to_h { |key, child| [ key.to_s.gsub(Manifest::UNSAFE_TEXT, ""), scrub(child) ] }
      when Array then value.map { |child| scrub(child) }
      when String then value.gsub(Manifest::UNSAFE_TEXT, "")
      else value
      end
    end

    def strip(value, stage, name, top: false)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), kept|
          if removable?(key, child, stage, name, top)
            @removed << key
            next
          end

          kept[key] = strip_child(key, child, stage, name)
        end
      when Array then value.map { |child| strip(child, stage, name) }
      else value
      end
    end

    def strip_child(key, child, stage, name)
      return strip(child, stage, name) unless Manifest::NAME_KEYED.include?(key) && child.is_a?(Hash)

      entries = child.to_a
      entries = entries.select { |pattern, _| keep_pattern?(pattern, stage) } if key == "patternProperties"
      @removed << key if entries.size < child.size
      entries.to_h { |entry_key, inner| [ entry_key, strip(inner, stage, name) ] }
    end

    def keep_pattern?(pattern, stage) = stage != :unsafe || linear_pattern?(pattern)

    def removable?(key, child, stage, name, top)
      case stage
      when :unsafe
        Manifest::FORBIDDEN_SCHEMA_KEYS.include?(key) || (key == "format" && child == "regex") || (key == "pattern" && !linear_pattern?(child))
      when :credential
        DATA_KEYWORDS.include?(key) && (credential_like?(child) || (top && fixed_secret?(key, child, name)))
      else
        DATA_KEYWORDS.include?(key)
      end
    end

    def fixed_secret?(key, child, name)
      %w[default const].include?(key) && name.match?(Manifest::CREDENTIAL_NAME) && child.is_a?(String) && child.present?
    end

    def credential_like?(value)
      case value
      when String then value.match?(Manifest::CREDENTIAL_VALUE)
      when Hash then value.each_value.any? { |inner| credential_like?(inner) }
      when Array then value.any? { |inner| credential_like?(inner) }
      else false
      end
    end

    def linear_pattern?(pattern)
      return false unless pattern.is_a?(String)

      Regexp.linear_time?(Regexp.new(JSONSchemer::EcmaRegexp.ruby_equivalent(pattern)))
    rescue StandardError
      false
    end
  end
end

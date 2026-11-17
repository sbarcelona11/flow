# frozen_string_literal: true

module Actions
  # What is wrong with an action step's kind_config against the project's
  # targets: a tool it cannot reach, an effect below the tool's own, arguments
  # the tool would refuse. Returns messages for `kind_config`.
  #
  # A server whose tools were never listed (Catalog#awaiting_tool_list?) is
  # accepted here with its arguments and effect unchecked — its schema and base
  # effect do not exist yet. The executor resolves the target through
  # Catalog#find before calling, so the action cannot run until they do.
  class TargetCheck
    PLACEHOLDER = /\{\{context:[^}]*\}\}/
    REPOSITORY_PARAMETER = "repository_id"

    def self.errors(project, kind_config) = new(project, kind_config).errors

    def initialize(project, kind_config)
      @catalog = Catalog.new(project)
      @config = kind_config.to_h
    end

    def errors
      target = @catalog.find(@config)
      return [] if target.nil? && @catalog.awaiting_tool_list?(@config)
      return [ "The action's tool is not available in this project." ] if target.nil?
      blocker = Connectors::Registry.for_target(target.type).new.action_blocker(target.input_schema)
      return [ blocker ] if blocker

      errors = []
      unless Effect.at_least?(@config["effect"], target.base_effect)
        errors << "The effect can't be lower than the tool's own (#{target.base_effect})."
      end
      argument_error = argument_error(target.input_schema)
      errors << "Arguments don't match the tool: #{argument_error}" if argument_error
      errors
    end

    private

    def argument_error(schema)
      arguments = @config["arguments"]
      return nil unless arguments.is_a?(Hash) && schema.is_a?(Hash)

      unknown = unknown_keys(arguments, schema)
      return "#{unknown.first} is not one of its arguments" if unknown.any?
      return nil if placeholder?(arguments)

      first = JSONSchemer.schema(schema).validate(arguments).first
      first && first["error"]
    rescue StandardError => e
      "its input schema can't be read (#{e.class.name.demodulize})"
    end

    # Extra keys are refused unless the schema asks for them: a misspelt
    # argument would otherwise be sent and silently ignored.
    def unknown_keys(arguments, schema)
      properties = schema["properties"]
      return [] unless properties.is_a?(Hash)
      return [] if schema["additionalProperties"] == true || schema["additionalProperties"].is_a?(Hash)

      arguments.keys.map(&:to_s) - properties.keys.map(&:to_s)
    end

    def placeholder?(value)
      case value
      when String then value.match?(PLACEHOLDER)
      when Hash then value.values.any? { |item| placeholder?(item) }
      when Array then value.any? { |item| placeholder?(item) }
      else false
      end
    end
  end
end

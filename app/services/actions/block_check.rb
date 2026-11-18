# frozen_string_literal: true

module Actions
  # What is wrong with an action step that records `block` against the project's
  # module registry. A block is a pre-configured view of one operation, so the
  # step must still be that operation, with arguments the block's config allows
  # and an effect no lower than the block's. Runs only when the step is saved:
  # a stored step keeps running if its block later changes, because execution
  # reads the step's own target and never the block, except that a capped step looks up the block's declared
  # cost_cents (which can only raise the estimate; a disabled or missing block adds none).
  class BlockCheck
    PLACEHOLDER = /\{\{(?:context|output):[^}]*\}\}/
    IDENTITY = %i[type mcp_server_id tool tool_id api_operation_id].freeze

    def self.errors(project, kind_config) = new(project, kind_config).errors

    def initialize(project, kind_config)
      @project = project
      @config = kind_config.to_h
      @ref = @config["block"].to_s
    end

    def errors
      entry = Modules::Registry.new(@project).block(@ref)
      return [ "The block #{@ref} is #{entry.status}: #{entry.reason}" ] unless entry.status == "valid"
      return [ "The block #{@ref} is not an action block." ] unless entry.executor == "action" && entry.target

      problems = []
      problems << "The action's tool is not the one block #{@ref} uses." unless same_target?(entry.target)
      problems << "The effect can't be lower than the block's own (#{entry.effect})." unless Effect.at_least?(@config["effect"], entry.effect)
      argument_error = argument_error(entry.config)
      problems << "Arguments don't match block #{@ref}: #{argument_error}" if argument_error
      name_problem = output_name_problem(entry)
      problems << name_problem if name_problem
      problems
    rescue Modules::Registry::Unknown => e
      [ e.message ]
    end

    private

    # The default name is the one a step carries when nobody chose, so only a name someone set can disagree.
    def output_name_problem(entry)
      port = entry.ports.to_h.fetch("out", {}).keys.first
      name = @config["output_name"]
      return nil if port.nil? || name.blank? || [ "#{port}.json", Step::ACTION_DEFAULT_OUTPUT_NAME ].include?(name)

      "The output name must be #{port}.json for block #{@ref}."
    end

    def same_target?(block_target)
      target = Catalog.new(@project).find(@config)
      !target.nil? && IDENTITY.all? { |field| target.public_send(field) == block_target.public_send(field) }
    end

    def argument_error(schema)
      arguments = @config["arguments"]
      return nil unless arguments.is_a?(Hash)

      settings = schema["properties"].is_a?(Hash) ? schema["properties"].keys.map(&:to_s) : []
      stray = arguments.keys.map(&:to_s) - settings
      return "#{stray.first} is not one of its settings" if stray.any?

      first_error(schema, arguments)
    rescue Regexp::TimeoutError
      "a pattern in its settings took too long to check"
    rescue StandardError => e
      "its settings can't be checked (#{e.class.name.demodulize})"
    end

    def first_error(schema, arguments)
      errors = JSONSchemer.schema(schema, regexp_resolver: "ecma").validate(arguments)
      found = errors.find { |error| error["data_pointer"].to_s.empty? || !placeholder?(value_at(arguments, error["data_pointer"])) }
      found && found["error"]
    end

    def value_at(root, pointer)
      pointer.to_s.split("/").reject(&:empty?).reduce(root) do |node, segment|
        case node
        when Hash then node[segment.gsub("~1", "/").gsub("~0", "~")]
        when Array then node[segment.to_i]
        end
      end
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

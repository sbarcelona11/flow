# frozen_string_literal: true

module Modules
  # Puts a block into a workflow the way the builder does: an action block becomes one action step, built as "Add from a
  # block" builds it; a composite is expanded into its ordinary steps. Call it inside Versions.save!, which runs the
  # save-time checks (Governance, OutputReferences) over the result. A step the workflow refuses raises
  # ActiveRecord::RecordInvalid and the whole save rolls back, so no step is ever dropped silently.
  class BlockInsertion
    class Refused < StandardError; end

    Result = Data.define(:steps, :warnings, :unbound)

    ROW_Y = 160

    def self.call(...) = new(...).call

    def initialize(project:, workflow:, ref:, bindings:)
      @project = project
      @workflow = workflow
      @ref = ref.to_s
      @bindings = bindings.to_h.stringify_keys
    end

    def call
      reviewed_definition!
      entry = Registry.new(@project).block(@ref)
      raise Refused, "#{@ref} can't be used: #{entry.reason}" unless entry.status == "valid"

      case entry.executor
      when "composite" then insert_composite
      when "action" then insert_action(entry)
      else raise Refused, "#{@ref} is not an action or a composite block, so it can't be added as a step."
      end
    rescue Registry::Unknown => e
      raise ActiveRecord::RecordNotFound, e.message
    end

    private

    # The registry lists enabled definitions, and the database refuses to enable an unreviewed one; this repeats the
    # check where the decision is made, and refuses a built-in, which is not a step an agent can place.
    def reviewed_definition!
      namespace, slug, version = Manifest.split_ref(@ref)
      definition = namespace && ModuleDefinition.for_project(@project).find_by(kind: "block", namespace: namespace, slug: slug, version: version)
      raise ActiveRecord::RecordNotFound, "Unknown block #{@ref}" unless definition
      problem = unusable_reason(definition)
      raise Refused, "#{@ref} is #{problem}. Only a block a person has approved and enabled can be added to a workflow." if problem
    end

    def unusable_reason(definition)
      return "archived" if definition.archived?
      return "rejected" if definition.rejected?
      return "waiting for review" unless definition.reviewed?

      "switched off" unless definition.enabled?
    end

    def insert_action(entry)
      raise Refused, "#{@ref} has no operation to call." unless entry.target

      out = entry.ports.to_h.fetch("out", {}).keys.first
      output_name = out ? "#{out}.json" : Step::ACTION_DEFAULT_OUTPUT_NAME
      config = { "target" => entry.target.type, "arguments" => @bindings, "effect" => entry.effect || "write",
                 "output_name" => output_name, "block" => @ref }.merge(identity(entry.target))
      step = @workflow.steps.create!(
        name: entry.label, kind: "action", position: next_position, kind_config: config,
        output_asset_specs: [ { "name" => output_name, "asset_type" => "file", "required" => true, "name_pattern" => nil } ]
      )
      Result.new(steps: [ step ], warnings: [], unbound: [])
    end

    def identity(target)
      case target.type
      when "wrapper" then { "tool_id" => target.tool_id }
      when "rest_operation" then { "api_operation_id" => target.api_operation_id }
      else { "mcp_server_id" => target.mcp_server_id, "tool" => target.tool }
      end
    end

    def insert_composite
      expanded = Composite::Expander.new(project: @project, ref: @ref, bindings: @bindings, workflow: @workflow,
                                         first_index: 1, at: { x: 0, y: below_existing }).call
      base = next_position
      specs = expanded.steps
      ids = {}
      created = dependency_order(specs).map do |spec|
        step = create_step(spec, base + specs.index(spec), ids)
        ids[spec["key"]] = step.id
        step
      end
      Result.new(steps: created.sort_by(&:position), warnings: expanded.warnings, unbound: expanded.unbound)
    rescue Composite::Expander::Refused => e
      raise Refused, e.message
    end

    def create_step(spec, position, ids)
      attrs = spec.slice(*WorkflowStepSync::STEP_COLUMNS).merge("position" => position)
      attrs["instructions"] = rewrite(attrs["instructions"], ids, %w[output step]) if attrs["instructions"]
      attrs["kind_config"] = rewrite_arguments(attrs["kind_config"], ids)
      attrs["depends_on_step_ids"] = Array(spec["depends_on_step_ids"]).map { |dependency| dependency.is_a?(String) ? known(ids, dependency) : dependency }
      step = @workflow.steps.create!(attrs.compact)
      Array(spec["sub_steps"]).each_with_index do |sub, index|
        text = sub["instructions"] && rewrite(sub["instructions"], ids, %w[output step])
        step.sub_steps.create!(name: sub["name"], instructions: text, required: sub.fetch("required", true), position: index + 1)
      end
      step
    end

    def known(ids, key) = ids.fetch(key) { raise Refused, "A step in #{@ref} depends on #{key}, which is not one of its steps." }

    def rewrite_arguments(config, ids)
      return config unless config.is_a?(Hash) && config["arguments"].is_a?(Hash)

      config.merge("arguments" => Actions::OutputInputs.map_strings(config["arguments"]) { |text| rewrite(text, ids, %w[output]) })
    end

    def rewrite(text, ids, types)
      InstructionReferences.rewrite(text) do |ref|
        mapped = ref.valid? && ref.id.is_a?(String) && ref.id.start_with?("new-") && ids[ref.id]
        next nil unless mapped && types.include?(ref.type)

        ref.type == "output" ? "{{output:#{mapped}:#{ref.name}}}" : "{{step:#{mapped}}}"
      end
    end

    # A step's draft dependencies come first, so each id exists when its dependants are saved.
    def dependency_order(specs)
      by_key = specs.index_by { |spec| spec["key"] }
      order = []
      visit = lambda do |key, trail|
        return if order.include?(key) || trail.include?(key) || !by_key.key?(key)

        Array(by_key[key]["depends_on_step_ids"]).each { |dependency| visit.call(dependency, trail + [ key ]) if dependency.is_a?(String) }
        order << key
      end
      specs.each { |spec| visit.call(spec["key"], []) }
      order.map { |key| by_key.fetch(key) }
    end

    def next_position = @workflow.steps.maximum(:position).to_i + 1

    def below_existing
      ys = @workflow.steps.not_deleted.filter_map { |step| step.canvas_position.to_h["y"] }
      ys.empty? ? 0 : (ys.max.to_i + ROW_Y).clamp(-Step::CANVAS_POSITION_LIMIT, Step::CANVAS_POSITION_LIMIT)
    end
  end
end

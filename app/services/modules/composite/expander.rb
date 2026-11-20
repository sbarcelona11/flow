# frozen_string_literal: true

module Modules
  module Composite
    # Turns an enabled composite block into ordinary steps in the aggregate's step shape, for the builder to put in its
    # draft or a tool to save. It never saves. Each step gets a fresh draft key `new-<n>` (from `first_index`), the
    # graph's dependencies as those keys, `{{output:…}}` and `{{step:…}}` tokens rewritten to them, the port bindings
    # substituted, a layout position, and `composite: {ref, instance, node}` as its only trace of the block.
    #
    # An instance is a copy: nothing is read from the module afterwards.
    class Expander
      Result = Struct.new(:steps, :warnings, :instance, :unbound, keyword_init: true)

      class Refused < StandardError; end

      COLUMN_X = 320
      ROW_Y = 160
      MAX_BINDING_BYTES = 4.kilobytes

      # @param bindings [Hash{String => String}] port name => `{{output:…}}`, `{{context:…}}` token or literal text
      # @param at [Hash] canvas position of the first column, `{x:, y:}`
      # @param workflow [Workflow, nil] when given, every expanded step is also validated as Step would on Save, so the
      #   caller learns now what the Save would refuse
      def initialize(project:, ref:, bindings: {}, instance: SecureRandom.uuid, first_index: 1, at: { x: 0, y: 0 }, workflow: nil)
        @project = project
        @ref = ref.to_s
        @bindings = bindings.to_h.stringify_keys
        @instance = instance
        @first_index = first_index.to_i
        @at = at.to_h.symbolize_keys
        @workflow = workflow
        @warnings = []
      end

      def call
        manifest = usable_manifest
        @in_ports = manifest.ports["in"]
        check_bindings!
        graph = manifest.graph["steps"]
        raise Refused, "This block has no steps." if graph.empty?

        @keys = graph.each_with_index.to_h { |step, index| [ step["key"], "new-#{@first_index + index}" ] }
        positions = layout(graph)
        steps = graph.map { |step| expand(step, manifest, positions.fetch(step["key"])) }
        check_steps!(steps) if @workflow
        Result.new(steps: steps, warnings: @warnings, instance: @instance, unbound: @in_ports.keys - @bindings.keys)
      end

      private

      def usable_manifest
        definition = ModuleDefinition.for_project(@project).enabled.where(kind: "block").find_by(**definition_attributes)
        raise ActiveRecord::RecordNotFound, "Unknown block #{@ref}" unless definition
        raise Refused, "#{@ref} is not reviewed." unless definition.reviewed? && !definition.rejected?

        entry = Registry.new(@project).block(@ref)
        raise Refused, "#{@ref} is not a composite block." unless entry.executor == "composite"
        raise Refused, "#{@ref} can't be used: #{entry.reason}" unless entry.status == "valid"

        entry.manifest
      rescue Registry::Unknown
        raise ActiveRecord::RecordNotFound, "Unknown block #{@ref}"
      end

      def definition_attributes
        namespace, slug, version = Manifest.split_ref(@ref)
        raise ActiveRecord::RecordNotFound, "Unknown block #{@ref}" unless namespace

        { namespace: namespace, slug: slug, version: version }
      end

      def check_bindings!
        unknown = @bindings.keys - @in_ports.keys
        raise Refused, "This block has no port #{unknown.first.inspect}." if unknown.any?

        @bindings.each do |name, value|
          raise Refused, "Port #{name} must be text." unless value.is_a?(String)
          raise Refused, "Port #{name} is longer than #{MAX_BINDING_BYTES / 1024} KB." if value.bytesize > MAX_BINDING_BYTES
          raise Refused, "Port #{name} can't hold another {{port:…}}." if value.match?(PORT_TOKEN)
          raise Refused, "Port #{name} has text that is not valid." if value.match?(Manifest::UNSAFE_TEXT) || !value.valid_encoding?
        end
      end

      def layout(graph)
        by_key = graph.index_by { |step| step["key"] }
        depth = {}
        depth_of = lambda do |key|
          depth[key] ||= 1 + (by_key[key]["depends_on"].to_a.grep_v(/\Aport:/).map { |dep| depth_of.call(dep) }.max || -1)
        end
        graph.each { |step| depth_of.call(step["key"]) }
        rows = Hash.new(0)
        graph.to_h do |step|
          column = depth[step["key"]]
          row = rows[column]
          rows[column] += 1
          [ step["key"], { "x" => (@at[:x].to_i + (column * COLUMN_X)).clamp(-Step::CANVAS_POSITION_LIMIT, Step::CANVAS_POSITION_LIMIT),
                           "y" => (@at[:y].to_i + (row * ROW_Y)).clamp(-Step::CANVAS_POSITION_LIMIT, Step::CANVAS_POSITION_LIMIT) } ]
        end
      end

      def expand(step, manifest, position)
        extra_deps = Set.new
        substitute = ->(text, whole:) { substitute_ports(text, whole: whole, deps: extra_deps) }
        attrs = { "key" => @keys.fetch(step["key"]), "name" => step["name"], "kind" => step["kind"], "canvas_position" => position,
                  "composite" => { "ref" => manifest.key, "instance" => @instance, "node" => step["key"] } }
        attrs["instructions"] = tokens(substitute.call(step["instructions"], whole: false)) if step["instructions"]
        config = step["kind_config"]&.deep_dup
        if config&.key?("arguments")
          config["arguments"] = Composite.map_strings(config["arguments"]) do |text|
            tokens(substitute.call(text, whole: text.match?(/\A\{\{port:[^{}\n]*\}\}\z/)))
          end
        end
        attrs["kind_config"] = config if config
        attrs["sub_steps"] = Array(step["sub_steps"]).map do |sub|
          { "name" => sub["name"], "instructions" => (tokens(substitute.call(sub["instructions"], whole: false)) if sub["instructions"]),
            "required" => sub.fetch("required", true) }.compact
        end
        step.except(*%w[key kind name instructions kind_config depends_on sub_steps]).each { |field, value| attrs[field] = value.deep_dup }
        attrs["budget_cents"] = nil if %w[approval wait].include?(step["kind"])
        carry_resources(attrs, step)
        attrs["depends_on_step_ids"] = dependencies(step, extra_deps)
        attrs.compact
      end

      def substitute_ports(text, whole:, deps:)
        text.gsub(PORT_TOKEN) do
          name = Regexp.last_match(1)
          bound = @bindings[name]
          deps.merge(dependency_ids(bound)) if bound
          bound.nil? ? (whole ? "" : name) : bound
        end
      end

      # `{{output:<graph key>:…}}` and `{{step:<graph key>}}` of the graph, to the draft keys.
      def tokens(text)
        text.gsub(OUTPUT_TOKEN) { @keys.key?(Regexp.last_match(1)) ? "{{output:#{@keys[Regexp.last_match(1)]}:#{Regexp.last_match(2)}}}" : Regexp.last_match(0) }
            .gsub(STEP_TOKEN) { @keys.key?(Regexp.last_match(1)) ? "{{step:#{@keys[Regexp.last_match(1)]}}}" : Regexp.last_match(0) }
      end

      def dependency_ids(value)
        InstructionReferences.scan(value).select { |ref| ref.valid? && %w[output step].include?(ref.type) }
                             .map { |ref| ref.id.match?(InstructionReferences::ID) ? ref.id.to_i : ref.id }
      end

      def dependencies(step, extra)
        deps = Array(step["depends_on"]).flat_map do |entry|
          next @keys.fetch(entry) unless entry.start_with?("port:")

          dependency_ids(@bindings[entry.delete_prefix("port:")].to_s)
        end
        (deps + extra.to_a).uniq
      end

      # Ids of rows that no longer exist are dropped, as a snapshot restore does; the ones that belong to another project
      # never get here (the registry reports such a block invalid).
      def carry_resources(attrs, step)
        ID_LISTS.each do |field, kind|
          ids = Array(step[field])
          next if ids.empty?

          kept = existing(kind, ids)
          @warnings << "#{step['name']}: #{ids.size - kept.size} #{kind.to_s.tr('_', ' ')} no longer exist and were left out." if kept.size < ids.size
          attrs[field] = kept
        end
        return unless step["agent_id"] && !Agent.exists?(step["agent_id"])

        @warnings << "#{step['name']}: its agent no longer exists, so the step has none."
        attrs.delete("agent_id")
      end

      def existing(kind, ids)
        klass = ProjectOwnedReferences::OWNERS.fetch(kind).call(@project).klass
        found = klass.unscoped.where(id: ids).pluck(:id).to_set
        ids.select { |id| found.include?(id) }
      end

      def check_steps!(steps)
        base = @workflow.steps.maximum(:position).to_i
        problems = steps.each_with_index.flat_map do |attrs, index|
          row = Step.new(attrs.slice(*Versions::Snapshots::Workflow::STEP_FIELDS, *Versions::Snapshots::Workflow::STEP_REFERENCES.keys)
                              .except("id", "depends_on_step_ids").merge("workflow_id" => @workflow.id, "position" => base + index + 1))
          row.valid? ? [] : row.errors.full_messages.map { |message| "#{attrs['name']}: #{message}" }
        end
        raise Refused, "This block can't be added here. #{problems.first(3).join(' ')}" if problems.any?
      end
    end
  end
end

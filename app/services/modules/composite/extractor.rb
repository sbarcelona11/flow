# frozen_string_literal: true

module Modules
  module Composite
    # "Save as block": turns a selection of a workflow's saved steps into a composite manifest.
    #
    # Ports are inferred from what crosses the selection boundary:
    # - an `{{output:<id>:<file>}}` of an unselected step, as a whole argument value or in agent instructions, becomes an
    #   in port named after the producer and the file (`{{port:<name>}}`);
    # - a dependency on an unselected step with no token becomes an in port that no token uses; the steps that waited on
    #   it list `port:<name>` in `depends_on`, so binding the port adds the dependency;
    # - an output of a selected step that an unselected step reads becomes an out port, and the caller may add more.
    #
    # Anything that cannot be read one way is refused with a sentence (Invalid), never guessed: more than MAX_STEPS steps,
    # a Wrapper action, an external output inside a longer argument string, a send or irreversible action whose approval
    # was left out, an unknown out port.
    class Extractor
      Result = Struct.new(:manifest, :warnings, keyword_init: true)

      class Invalid < StandardError; end

      def initialize(workflow:, step_ids:, label:, description: nil, namespace: BlockBuilder::DEFAULT_NAMESPACE, slug: nil, out_ports: [])
        @workflow = workflow
        @requested = Array(step_ids)
        @label = label.to_s.strip
        @description = description.presence
        @namespace = namespace
        @slug = slug
        @extra_out = Array(out_ports)
        @warnings = []
        @in_ports = {}
        @out_ports = {}
        @token_producers = Hash.new { |hash, id| hash[id] = Set.new }
      end

      def manifest
        load_steps!
        assign_keys
        check_governance!
        ActiveRecord::Associations::Preloader.new(records: @steps, associations: %i[sub_steps resource_links]).call
        graph = @steps.map { |step| graph_step(step) }
        collect_out_ports!
        manifest = { "kind" => "block", "namespace" => @namespace, "slug" => pick_slug, "version" => 1, "label" => @label,
                     "executor" => "composite", "ports" => { "in" => @in_ports, "out" => @out_ports }, "graph" => { "steps" => graph } }
        manifest["description"] = @description if @description
        Result.new(manifest: Manifest.from_hash(manifest).to_h.deep_dup, warnings: @warnings)
      rescue Manifest::Invalid => e
        raise Invalid, "This selection can't be saved as a block: #{e.message}"
      end

      private

      def load_steps!
        raise Invalid, "Give the block a name." if @label.blank?

        ids = @requested.map { |id| id.to_s.match?(/\A[1-9]\d*\z/) ? id.to_i : nil }
        raise Invalid, "Pick at least one step." if ids.empty? || ids.any?(&:nil?)
        raise Invalid, "Pick each step once." if ids.uniq.size != ids.size
        raise Invalid, "A block holds at most #{MAX_STEPS} steps; you picked #{ids.size}." if ids.size > MAX_STEPS

        live = @workflow.steps.not_deleted.reorder(:position).to_a
        @all = live.index_by(&:id)
        missing = ids - @all.keys
        raise Invalid, "Steps #{missing.join(', ')} are not in this workflow. Save the workflow first, then pick again." if missing.any?

        @steps = live.select { |step| ids.include?(step.id) }
        wrapper = @steps.find { |step| step.action? && step.kind_config["target"] == "wrapper" }
        raise Invalid, "#{wrapper.name} is a Wrapper action, which a block can't hold. Leave it out." if wrapper

        flattened = @steps.count { |step| step.composite.present? }
        @warnings << "#{flattened} step(s) were part of another block; they are saved as plain steps." if flattened.positive?
      end

      def assign_keys
        taken = Set.new
        @keys = @steps.to_h do |step|
          base = slug_of(step.name, "_", fallback: "step")[0, 60]
          key = first_free(base) { |candidate| taken.include?(candidate) }
          taken << key
          [ step.id, key ]
        end
      end

      # `base`, else `base_2`, `base_3`, ...: the counter advances whatever is taken, so it always terminates.
      def first_free(base)
        return base unless yield(base)

        (2..).lazy.map { |n| "#{base}_#{n}" }.find { |candidate| !yield(candidate) }
      end

      def slug_of(text, joiner, fallback:)
        plain = text.to_s.unicode_normalize(:nfkd).gsub(/[^\x00-\x7F]/, "").downcase.gsub(/[^a-z0-9]+/, joiner).gsub(/\A#{joiner}+|#{joiner}+\z/, "")
        plain = "#{fallback}#{joiner}#{plain}" if plain.match?(/\A\d/)
        plain.presence || fallback
      end

      # The send/irreversible rule of Actions::Governance, on the selection alone, with the answer a person can act on.
      def check_governance!
        selected = @keys.keys.to_set
        @steps.each do |step|
          next unless step.action? && Actions::Effect.needs_approval?(step.kind_config["effect"])

          approvals = step.depends_on_step_ids.filter_map { |id| @all[id] }.select { |dep| Actions::Governance.blocking_approval?(dep) }
          next if approvals.any? { |dep| selected.include?(dep.id) }

          left_out = approvals.map(&:name).first
          raise Invalid, "Include the approval step #{left_out} in the block: #{step.name} (#{step.kind_config['effect']}) must run after it." if left_out

          raise Invalid, "#{step.name} (#{step.kind_config['effect']}) has no approval step before it, so it can't be saved as a block."
        end
      end

      def graph_step(step)
        dropped = [ ("reasoning effort" if step.reasoning_effort.present?), ("BMAD" if step.bmad_enabled) ].compact
        @warnings << "#{step.name}: #{dropped.join(' and ')} can't be kept in a block; set it again after inserting." if dropped.any?
        entry = { "key" => @keys.fetch(step.id), "kind" => step.kind.to_s, "name" => step.name }
        entry["instructions"] = rewrite_text(step, step.instructions) if step.instructions.present?
        config = config_for(step)
        entry["kind_config"] = config if config.present?
        deps = dependencies_for(step)
        entry["depends_on"] = deps if deps.any?
        subs = step.sub_steps.reject(&:deleted?).sort_by { |sub| [ sub.position, sub.id ] }
        entry["sub_steps"] = subs.map { |sub| { "name" => sub.name, "instructions" => (rewrite_text(step, sub.instructions) if sub.instructions.present?), "required" => sub.required }.compact } if subs.any?
        entry.merge!(settings_for(step))
        entry
      end

      def config_for(step)
        config = step.kind_config.deep_dup
        return config unless step.action? && config["arguments"].is_a?(Hash)

        config["arguments"] = Composite.map_strings(config["arguments"]) { |text| rewrite_argument(step, text) }
        config
      end

      def settings_for(step)
        entry = { "budget_cents" => step.budget_cents, "agent_id" => step.agent_id, "preferred_model" => step.preferred_model,
                  "required_agent_runtime" => step.required_agent_runtime }
        entry["on_failure"] = step.on_failure.to_s unless step.on_failure.to_s == "fail"
        entry["max_retries"] = step.max_retries unless step.max_retries.to_i.zero?
        entry["skip_policy"] = step.skip_policy.to_s unless step.skip_policy.to_s == "never"
        entry["allow_non_interactive"] = true if step.allow_non_interactive && step.runs_session?
        entry["input_asset_specs"] = spec_list(step.input_asset_specs)
        entry["output_asset_specs"] = spec_list(step.output_asset_specs) unless step.action?
        Composite::ID_LISTS.each_key { |field| entry[field] = step.public_send(field) }
        entry.reject { |_, value| value.nil? || value == [] }
      end

      def spec_list(specs)
        DataFlow::AssetSpec.list(specs).map(&:to_h).map { |spec| spec.stringify_keys.compact }.presence
      end

      def dependencies_for(step)
        step.depends_on_step_ids.filter_map do |id|
          next @keys[id] if @keys.key?(id)

          producer = @all[id]
          next if producer.nil? || @token_producers[step.id].include?(id)

          "port:#{in_port_for(producer, nil)}"
        end.uniq
      end

      def rewrite_text(step, text)
        InstructionReferences.rewrite(text) { |ref| token_for(step, ref, whole: false) }
      end

      def rewrite_argument(step, text)
        whole = text.match?(/\A\{\{output:[^{}\n]+\}\}\z/)
        InstructionReferences.rewrite(text) { |ref| token_for(step, ref, whole: whole) }
      end

      def token_for(step, ref, whole:)
        return nil unless ref.valid? && %w[output step].include?(ref.type) && ref.id.match?(InstructionReferences::ID)

        id = ref.id.to_i
        return (ref.type == "output" ? "{{output:#{@keys[id]}:#{ref.name}}}" : "{{step:#{@keys[id]}}}") if @keys.key?(id)

        producer = @all[id]
        unless producer
          raise Invalid, "#{step.name} mentions a step (#{id}) that no longer exists in this workflow. Fix or remove that reference, then save the block."
        end

        if ref.type == "step"
          @warnings << "#{step.name} mentioned #{producer.name}, which is not in the block; it now says its name."
          return producer.name.to_s.delete("{}")
        end
        unless whole || !step.action?
          raise Invalid, "#{step.name} reads #{producer.name}'s #{ref.name} inside a longer argument. Make that argument just the output, " \
                         "or include #{producer.name} in the block."
        end

        @token_producers[step.id] << id
        "{{port:#{in_port_for(producer, ref.name)}}}"
      end

      def in_port_for(producer, file)
        base = slug_of([ producer.name, file&.sub(/\.[^.]*\z/, "") ].compact.join(" "), "_", fallback: "input")[0, 60]
        source = [ producer.id, file ]
        name = @in_ports.find { |_, port| port["x-source"] == source }&.first
        name ||= first_free(base) { |candidate| @in_ports.key?(candidate) }
        @in_ports[name] ||= { "x-source" => [ producer.id, file ], "description" => file ? "#{producer.name}: #{file}" : "Runs after #{producer.name}" }
        name
      end

      def collect_out_ports!
        selected = @keys.keys.to_set
        @all.each_value do |reader|
          next if selected.include?(reader.id)

          each_output_ref(reader) do |ref|
            next unless selected.include?(ref.id.to_i)

            add_out_port(@all.fetch(ref.id.to_i), ref.name)
          end
        end
        @extra_out.each do |wanted|
          wanted = wanted.to_h.stringify_keys
          step = @steps.find { |candidate| candidate.id == wanted["step_id"].to_i }
          raise Invalid, "Out port #{wanted['output']}: step #{wanted['step_id']} is not in the selection." unless step

          add_out_port(step, wanted["output"])
        end
        @in_ports.each_value { |port| port.delete("x-source") }
      end

      def each_output_ref(step)
        texts = [ step.instructions ]
        Composite.each_string(step.kind_config["arguments"]) { |text| texts << text } if step.action?
        texts.compact.each { |text| InstructionReferences.scan(text).each { |ref| yield ref if ref.valid? && ref.type == "output" && ref.id.match?(InstructionReferences::ID) } }
      end

      def add_out_port(step, file)
        declared = step.action? ? [ step.kind_config["output_name"].presence || Step::ACTION_DEFAULT_OUTPUT_NAME ] : step.output_specs.map(&:name)
        raise Invalid, "#{step.name} does not declare an output #{file}." unless declared.include?(file)

        name = slug_of("#{step.name} #{file.sub(/\.[^.]*\z/, '')}", "_", fallback: "output")[0, 60]
        mine = { "step" => @keys.fetch(step.id), "output" => file }
        return if @out_ports.value?(mine)

        name = first_free(name) { |candidate| @out_ports.key?(candidate) }
        @out_ports[name] = { "step" => @keys.fetch(step.id), "output" => file }
      end

      def pick_slug
        base = @slug.presence || slug_of(@label, "-", fallback: "block")[0, 64].delete_suffix("-")
        taken = ModuleDefinition.for_project(@workflow.scope).where(kind: "block", namespace: @namespace).pluck(:slug).to_set
        return base unless taken.include?(base)

        (2..).lazy.map { |n| "#{base[0, 60]}-#{n}" }.find { |candidate| taken.exclude?(candidate) }
      end
    end
  end
end

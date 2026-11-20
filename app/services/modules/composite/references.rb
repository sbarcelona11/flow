# frozen_string_literal: true

module Modules
  module Composite
    # The project rows a composite's steps name by id. A composite is project-scoped, so every id must belong to the
    # project (never another project's or company's): that is checked when the block is listed, enabled and expanded.
    # Ids of rows that no longer exist are not an error for a resource list; the expansion drops them with a warning,
    # as a snapshot restore does. An action's own target (server, Wrapper, REST operation) is not droppable.
    class References
      TOKEN_KINDS = { "asset" => :assets, "mcp" => :mcp_servers, "tool" => :tools, "skill" => :skills, "config_item" => :config_items }.freeze
      TARGETS = { "mcp_server_id" => :mcp_servers, "tool_id" => :tools }.freeze

      def initialize(project, steps)
        @project = project
        @steps = steps
      end

      # { kind => [ids] } over the steps' lists, `agent_id`, and the `{{asset:…}}`-style tokens in instructions.
      def lists
        found = Hash.new { |hash, kind| hash[kind] = Set.new }
        @steps.each do |step|
          found[:agents] << step["agent_id"] if step["agent_id"]
          ID_LISTS.each { |field, kind| found[kind].merge(Array(step[field])) }
          texts(step).each { |text| TOKEN_KINDS.each { |type, kind| found[kind].merge(InstructionReferences.ids(text, type)) } }
        end
        found.transform_values(&:to_a)
      end

      # Ids that belong to another project or company.
      def foreign
        lists.filter_map do |kind, ids|
          bad = ProjectOwnedReferences.foreign_ids(@project, kind, ids, lenient: true)
          [ kind, bad ] if bad.any?
        end.to_h
      end

      # The first sentence to say why the composite cannot be used in this project, or nil.
      def problem
        foreign_ids = foreign
        return "it names #{foreign_ids.keys.first.to_s.tr('_', ' ')} ids outside this project (#{foreign_ids.values.first.sort.join(', ')})." if foreign_ids.any?

        @steps.each do |step|
          message = target_problem(step)
          return message if message
        end
        nil
      end

      private

      def texts(step)
        [ step["instructions"] ] + Array(step["sub_steps"]).map { |sub| sub["instructions"] } + argument_texts(step)
      end

      def argument_texts(step)
        texts = []
        Composite.each_string(step.dig("kind_config", "arguments")) { |text| texts << text }
        texts
      end

      def target_problem(step)
        config = step["kind_config"]
        return unless step["kind"] == "action" && config

        TARGETS.each do |field, kind|
          id = config[field]
          next unless id

          owned = ProjectOwnedReferences::OWNERS.fetch(kind).call(@project).exists?(id: id)
          return "step #{step['key']} names #{field.tr('_', ' ')} #{id}, which this project does not have." unless owned
        end
        operation = config["api_operation_id"]
        return unless operation && !project_operations.exists?(id: operation)

        "step #{step['key']} names REST operation #{operation}, which this project does not have."
      end

      def project_operations
        ApiOperation.joins(:api_connector).where(api_connectors: { scope_type: "Project", scope_id: @project.id, archived_at: nil })
      end
    end
  end
end

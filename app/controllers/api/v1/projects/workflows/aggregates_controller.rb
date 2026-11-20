# frozen_string_literal: true

module Api
  module V1
    module Projects
      module Workflows
        # The builder's Save: the whole workflow — its fields, every step in
        # order and each step's sub-steps — in one request, applied in one
        # transaction and recorded as one version. `base_version` is the version
        # the editor loaded; a newer one answers 409 instead of overwriting.
        class AggregatesController < Workflows::ApplicationController
          STEP_FIELDS = [
            :id, :key, :name, :instructions, :kind, :agent_id, :budget_cents, :allow_non_interactive, :skip_policy, :on_failure,
            :max_retries, :bmad_enabled, :required_agent_runtime, :preferred_model, :reasoning_effort,
            { kind_config: KIND_CONFIG_FIELDS,
              canvas_position: %i[x y],
              input_asset_specs: %i[name asset_type required],
              output_asset_specs: %i[name asset_type required name_pattern],
              tool_ids: [], mcp_server_ids: [], skill_ids: [], asset_ids: [], repository_ids: [],
              config_item_ids: [], depends_on_step_ids: [],
              sub_steps: %i[id name instructions required] }
          ].freeze

          RAW_STEP_KEYS = %w[budget_cents composite].freeze

          def update
            workflow = current_workflow
            payload = aggregate_params
            WorkflowAggregateSave.new(workflow, payload).validate!
            version = Versions.save!(workflow, actor: version_actor, base_version: params.require(:base_version)) do
              WorkflowAggregateSave.new(workflow, payload).apply!
            end
            workflow.reload

            render json: {
              workflow: WorkflowResource.new(workflow).to_h,
              steps: workflow.steps.not_deleted.includes(:sub_steps, :resource_links).map { |s| StepResource.new(s).to_h },
              currentVersionNumber: workflow.current_version_number,
              versionCreated: version.present?,
              issues: DataFlow::Check.for_workflow(workflow, project: current_project).issues.map(&:as_json)
            }
          rescue WorkflowAggregateSave::Invalid => e
            render json: { errors: [ e.message ] }, status: :unprocessable_entity
          end

          # The same check as after a Save, over the editor's unsaved payload, so
          # the builder can show what a run would trip on while it is edited.
          def check
            issues = DataFlow::Check.for_payload(current_workflow, aggregate_params, project: current_project).issues
            render json: { issues: issues.map(&:as_json) }
          end

          private

          # The id/key of a step element that sends `canvas_position: null`; matched by identity because `permit`
          # drops malformed elements and indexes would no longer line up.
          def null_identity(raw_step, key)
            return unless raw_step.respond_to?(:key?) && raw_step.key?(key) && raw_step[key].nil?

            (raw_step["key"].presence || raw_step["id"].presence)&.to_s
          end

          # [identity, raw value] of a step element that sends `key`, whatever its type.
          def raw_entry(raw_step, key)
            return unless raw_step.respond_to?(:key?) && raw_step.key?(key)

            identity = (raw_step["key"].presence || raw_step["id"].presence)&.to_s
            value = raw_step[key]
            [ identity, value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value ] if identity
          end

          def aggregate_params
            raw = params.require(:aggregate)
            permitted = raw.permit(:name, :description, :runner_id, :budget_cents, config: {}, steps: STEP_FIELDS).to_h
            keep_raw_cap(permitted, raw, "budget_cents")
            RAW_STEP_KEYS.each do |key|
              sent_values = raw[:steps].is_a?(Array) ? raw[:steps].filter_map { |s| raw_entry(s, key) } : []
              Array(permitted["steps"]).each do |step|
                identity = (step["key"].presence || step["id"]).to_s
                sent = sent_values.find { |entry| entry[0] == identity }
                step[key] = sent[1] if sent
              end
            end
            NULLABLE_STEP_KEYS.each do |key|
              cleared = raw[:steps].is_a?(Array) ? raw[:steps].filter_map { |s| null_identity(s, key) } : []
              Array(permitted["steps"]).each do |step|
                step[key] = nil if cleared.include?((step["key"].presence || step["id"]).to_s)
              end
            end
            permitted
          end
        end
      end
    end
  end
end

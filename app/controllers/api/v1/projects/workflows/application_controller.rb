# frozen_string_literal: true

module Api
  module V1
    module Projects
      module Workflows
        class ApplicationController < Api::V1::Projects::ApplicationController
          KIND_CONFIG_FIELDS = [
            :timeout_seconds, :on_timeout, :delay_seconds, :until_context_key,
            :target, :mcp_server_id, :tool, :tool_id, :api_operation_id, :effect, :output_name, :block, { arguments: {} }
          ].freeze

          # Step keys a client clears by sending null ("back to auto-layout", "no cap").
          NULLABLE_STEP_KEYS = %w[canvas_position].freeze

          private

          def versioned(&)
            Versions.save!(current_workflow, actor: version_actor, base_version: params[:base_version], &)
          end

          def current_workflow
            @current_workflow ||= current_project.workflows.active.find(params[:workflow_id])
          end

          # `permit` drops a key whose value is null for a hash filter, which would make clearing it unsendable.
          def keep_null(permitted, raw, key)
            permitted[key] = nil if raw.respond_to?(:key?) && raw.key?(key) && raw[key].nil?
            permitted
          end

          # `permit` drops a non-scalar cap (array, hash) and the model cannot refuse what it never sees, so the raw
          # value of a key that was sent goes through; the model refuses anything but an integer or null.
          def keep_raw_cap(permitted, raw, key)
            permitted[key] = raw[key].respond_to?(:to_unsafe_h) ? raw[key].to_unsafe_h : raw[key] if raw.respond_to?(:key?) && raw.key?(key)
            permitted
          end

          def step_params
            permitted = params.require(:step).permit(
              :name, :instructions, :position, :agent_id, :kind, :budget_cents,
              :allow_non_interactive, :skip_policy, :on_failure, :max_retries,
              :bmad_enabled, :required_agent_runtime, :preferred_model, :reasoning_effort,
              kind_config: KIND_CONFIG_FIELDS, canvas_position: %i[x y],
              input_asset_specs: [ :name, :asset_type, :required ],
              output_asset_specs: [ :name, :asset_type, :required, :name_pattern ],
              tool_ids: [], mcp_server_ids: [], skill_ids: [], asset_ids: [], repository_ids: [],
              config_item_ids: [],
              depends_on_step_ids: [],
              sub_steps_attributes: %i[id position name instructions required _destroy]
            )
            NULLABLE_STEP_KEYS.each { |key| keep_null(permitted, params[:step], key) }
            keep_raw_cap(permitted, params[:step], "budget_cents")
            permitted
          end
        end
      end
    end
  end
end

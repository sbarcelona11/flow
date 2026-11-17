# frozen_string_literal: true

module Api
  module V1
    module Projects
      module Workflows
        class ApplicationController < Api::V1::Projects::ApplicationController
          KIND_CONFIG_FIELDS = [
            :timeout_seconds, :on_timeout, :delay_seconds, :until_context_key,
            :target, :mcp_server_id, :tool, :tool_id, :api_operation_id, :effect, :output_name, { arguments: {} }
          ].freeze

          private

          def versioned(&)
            Versions.save!(current_workflow, actor: version_actor, base_version: params[:base_version], &)
          end

          def current_workflow
            @current_workflow ||= current_project.workflows.active.find(params[:workflow_id])
          end

          def step_params
            params.require(:step).permit(
              :name, :instructions, :position, :agent_id, :kind,
              :allow_non_interactive, :skip_policy, :on_failure, :max_retries,
              :bmad_enabled, :required_agent_runtime, :preferred_model, :reasoning_effort,
              kind_config: KIND_CONFIG_FIELDS,
              input_asset_specs: [ :name, :asset_type, :required ],
              output_asset_specs: [ :name, :asset_type, :required, :name_pattern ],
              tool_ids: [], mcp_server_ids: [], skill_ids: [], asset_ids: [], repository_ids: [],
              config_item_ids: [],
              depends_on_step_ids: [],
              sub_steps_attributes: %i[id position name instructions required _destroy]
            )
          end
        end
      end
    end
  end
end

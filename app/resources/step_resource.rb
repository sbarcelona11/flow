# frozen_string_literal: true

class StepResource < ApplicationResource
  KIND_TYPE = "'agent' | 'approval' | 'wait' | 'action'"
  KIND_CONFIG_TYPE = "{ timeoutSeconds?: number; onTimeout?: 'fail' | 'skip'; delaySeconds?: number; untilContextKey?: string; " \
                     "target?: 'mcp_tool' | 'wrapper' | 'rest_operation'; mcpServerId?: number; tool?: string; toolId?: number; " \
                     "apiOperationId?: number; " \
                     "arguments?: Record<string, unknown>; effect?: 'read' | 'write' | 'send' | 'irreversible'; outputName?: string }"

  # `arguments` are named by the tool: they leave verbatim, not camelized.
  def self.kind_config_for(config)
    config = (config || {}).to_h
    return config unless config["arguments"].is_a?(Hash)

    config.merge("arguments" => DeepKeyCamelizer.verbatim(config["arguments"]))
  end

  attributes :id, :name, :instructions, :position,
             :allow_non_interactive, :skip_policy, :on_failure, :max_retries,
             :bmad_enabled, :preferred_model, :reasoning_effort,
             :created_at, :updated_at

  typelize KIND_TYPE
  attribute :kind do |step|
    step.kind.to_s
  end

  typelize KIND_CONFIG_TYPE
  attribute :kind_config do |step|
    StepResource.kind_config_for(step.kind_config)
  end

  typelize "number[]"
  attribute :repository_ids do |step|
    step.repository_ids || []
  end

  typelize "number[]"
  attribute :depends_on_step_ids do |step|
    step.depends_on_step_ids || []
  end

  typelize "Array<{ name: string; assetType: string; required: boolean }>"
  attribute :input_asset_specs do |step|
    val = step.input_asset_specs
    val.is_a?(String) ? JSON.parse(val) : (val || [])
  end

  typelize "Array<{ name: string; assetType: string; required: boolean; namePattern?: string | null }>"
  attribute :output_asset_specs do |step|
    val = step.output_asset_specs
    val.is_a?(String) ? JSON.parse(val) : (val || [])
  end

  attribute :agent_id do |step|
    step.agent_id
  end

  attribute :required_agent_runtime do |step|
    step.required_agent_runtime
  end

  typelize "number[]"
  attribute :tool_ids do |step|
    step.tool_ids || []
  end

  typelize "number[]"
  attribute :mcp_server_ids do |step|
    step.mcp_server_ids || []
  end

  typelize "number[]"
  attribute :skill_ids do |step|
    step.skill_ids || []
  end

  typelize "number[]"
  attribute :config_item_ids do |step|
    step.config_item_ids || []
  end

  typelize "number[]"
  attribute :asset_ids do |step|
    step.asset_ids || []
  end

  typelize "SubStep[]"
  attribute :sub_steps do |step|
    step.sub_steps.select { |ss| ss.deleted_at.nil? }.map do |ss|
      SubStepResource.new(ss).to_h
    end
  end
end

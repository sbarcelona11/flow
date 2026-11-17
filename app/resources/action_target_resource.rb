# frozen_string_literal: true

class ActionTargetResource < ApplicationResource
  preserve_keys :input_schema

  typelize type: "'mcp_tool' | 'wrapper' | 'rest_operation'", mcp_server_id: "number | null",
           server_name: "string | null", tool: "string | null", tool_id: "number | null",
           api_operation_id: "number | null", name: :string, description: "string | null",
           input_schema: "Record<string, unknown>", base_effect: "'read' | 'write' | 'send' | 'irreversible'",
           drifted: :boolean, http_method: "'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE' | null", path: "string | null"
  attributes :type, :mcp_server_id, :server_name, :tool, :tool_id, :api_operation_id, :name, :description, :input_schema,
             :base_effect, :drifted, :http_method, :path
end

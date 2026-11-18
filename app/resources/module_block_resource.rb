# frozen_string_literal: true

class ModuleBlockResource < ApplicationResource
  preserve_keys :ports, :config

  typelize key: :string, label: :string, description: "string | null", executor: "'action' | 'agent' | 'control' | null",
           ports: "{ in?: Record<string, string>; out?: Record<string, string> }", config: "Record<string, unknown>",
           status: "'valid' | 'invalid' | 'unresolved'", reason: "string | null", unresolved: :boolean,
           effect: "'read' | 'write' | 'send' | 'irreversible' | null",
           target: "{ type: 'mcp_tool' | 'wrapper' | 'rest_operation'; connection: string | null; operation: string; " \
                   "name: string; mcpServerId: number | null; tool: string | null; toolId: number | null; " \
                   "apiOperationId: number | null } | null"
  attributes :key, :label, :executor, :config, :status, :reason, :unresolved, :effect

  typelize origin: "'web' | 'builder' | 'mcp' | 'builtin'", review_state: "'reviewed' | 'waiting'"
  attribute(:origin) { |entry| entry.builtin ? "builtin" : definition_for(entry)&.origin || "web" }
  attribute(:review_state) { |entry| entry.builtin ? "reviewed" : definition_for(entry)&.review_state || "reviewed" }

  attribute(:description) { |entry| entry.manifest&.description }
  attribute(:ports) { |entry| entry.ports || {} }

  attribute :target do |entry|
    target = entry.target
    next unless target

    { type: target.type, connection: target.server_name, operation: entry.operation.key, name: target.name,
      mcp_server_id: target.mcp_server_id, tool: target.tool, tool_id: target.tool_id,
      api_operation_id: target.api_operation_id }
  end

  private

  def definition_for(entry)
    (params[:definitions] || {})[entry.key]
  end
end

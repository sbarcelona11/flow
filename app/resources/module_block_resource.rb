# frozen_string_literal: true

class ModuleBlockResource < ApplicationResource
  preserve_keys :ports, :config, :composite

  typelize key: :string, label: :string, description: "string | null", executor: "'action' | 'agent' | 'control' | 'composite' | null",
           ports: "{ in?: Record<string, string>; out?: Record<string, string> }", config: "Record<string, unknown>",
           status: "'valid' | 'invalid' | 'unresolved'", reason: "string | null", unresolved: :boolean,
           effect: "'read' | 'write' | 'send' | 'irreversible' | null",
           target: "{ type: 'mcp_tool' | 'wrapper' | 'rest_operation'; connection: string | null; operation: string; " \
                   "name: string; mcpServerId: number | null; tool: string | null; toolId: number | null; " \
                   "apiOperationId: number | null } | null"
  attributes :key, :label, :executor, :config, :status, :reason, :unresolved, :effect

  typelize origin: "'web' | 'builder' | 'mcp' | 'builtin' | null", review_state: "'reviewed' | 'waiting' | 'rejected' | null"
  attribute(:origin) { |entry| entry.builtin ? "builtin" : definition_for(entry)&.origin }
  attribute(:review_state) { |entry| entry.builtin ? "reviewed" : definition_for(entry)&.review_state }

  attribute(:description) { |entry| entry.manifest&.description }
  # A composite's ports carry more than a type; `composite` holds them in full, `ports` keeps the typed ones.
  attribute(:ports) do |entry|
    ports = entry.ports || {}
    entry.executor == "composite" ? ports.transform_values { |side| side.filter_map { |name, port| [ name, port["type"] ] if port["type"] }.to_h } : ports
  end

  typelize composite: "{ ports: { in: Record<string, { type: string | null; description: string | null }>; " \
                      "out: Record<string, { type: string | null; step: string; output: string }> }; " \
                      "steps: Array<{ key: string; name: string; kind: 'agent' | 'approval' | 'wait' | 'action' }> } | null"
  attribute :composite do |entry|
    next unless entry.executor == "composite"

    ports = entry.ports
    { ports: { in: ports["in"].transform_values { |port| { type: port["type"], description: port["description"] } },
               out: ports["out"].transform_values { |port| { type: port["type"], step: port["step"], output: port["output"] } } },
      steps: entry.manifest.graph["steps"].map { |step| { key: step["key"], name: step["name"], kind: step["kind"] } } }
  end

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

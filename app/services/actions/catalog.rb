# frozen_string_literal: true

module Actions
  # What a project's action steps can call: each tool of its enabled http/sse MCP
  # servers whose baseline holds the tools' schemas, its enabled Wrappers, and the
  # enabled operations of its enabled REST connectors.
  # A stdio server is never a target: Rails cannot reach it (D9).
  class Catalog
    Target = Data.define(:type, :mcp_server_id, :server_name, :tool, :tool_id, :api_operation_id, :name, :description,
                         :input_schema, :base_effect, :drifted)

    CALLABLE_TRANSPORTS = %w[http sse].freeze

    def initialize(project)
      @project = project
    end

    def targets
      mcp_servers.order(:name).flat_map { |server| server_targets(server) } +
        wrappers.order(:name).map { |tool| wrapper_target(tool) } +
        rest_operations.order("api_connectors.name", :name).map { |operation| rest_target(operation) }
    end

    def find(kind_config)
      config = kind_config.to_h
      case config["target"]
      when "mcp_tool"
        server = mcp_servers.find_by(id: config["mcp_server_id"])
        server && server_targets(server).find { |target| target.tool == config["tool"] }
      when "wrapper"
        tool = wrappers.find_by(id: config["tool_id"])
        tool && wrapper_target(tool)
      when "rest_operation"
        operation = rest_operations.find_by(id: config["api_operation_id"])
        operation && rest_target(operation)
      end
    end

    # A callable server whose tools were never listed: a template install or a
    # copy into another project creates it, and its tools are probed after commit.
    def awaiting_tool_list?(kind_config)
      config = kind_config.to_h
      config["target"] == "mcp_tool" && mcp_servers.where(id: config["mcp_server_id"], tool_snapshot_at: nil).exists?
    end

    private

    def mcp_servers
      MCPServer.for_project(@project).enabled.unarchived.where(transport: CALLABLE_TRANSPORTS)
    end

    def wrappers
      Tool.for_project(@project).enabled
    end

    def rest_operations
      ApiOperation.enabled.joins(:api_connector).merge(ApiConnector.for_project(@project).enabled)
                  .includes(:api_connector)
    end

    def server_targets(server)
      return [] unless server.tool_baseline? && server.tool_schemas_stored?

      Array(server.tool_snapshot["tools"]).sort_by { |tool| tool["name"].to_s }.map do |tool|
        Target.new(type: "mcp_tool", mcp_server_id: server.id, server_name: server.name, tool: tool["name"], tool_id: nil,
                   api_operation_id: nil, name: tool["name"], description: tool["description"], input_schema: tool["input_schema"] || {},
                   base_effect: Effect.base_for_annotations(tool["annotations"]),
                   drifted: MCP::ToolDriftDetector.drifted_tool?(server, tool["name"]))
      end
    end

    def wrapper_target(tool)
      Target.new(type: "wrapper", mcp_server_id: nil, server_name: nil, tool: nil, tool_id: tool.id, api_operation_id: nil,
                 name: tool.display_name.presence || tool.name, description: tool.description,
                 input_schema: tool.input_schema.as_json || {}, base_effect: Effect.base_for_wrapper, drifted: false)
    end

    def rest_target(operation)
      Target.new(type: "rest_operation", mcp_server_id: nil, server_name: operation.api_connector.name, tool: nil, tool_id: nil,
                 api_operation_id: operation.id, name: operation.name, description: operation.description,
                 input_schema: operation.input_schema || {}, base_effect: Effect.base_for_operation(operation),
                 drifted: false)
    end
  end
end

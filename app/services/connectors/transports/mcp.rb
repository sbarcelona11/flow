# frozen_string_literal: true

module Connectors
  module Transports
    class MCP < Transport
      CALLABLE_TRANSPORTS = %w[http sse].freeze

      transport :mcp, target: "mcp_tool", position: 1

      def connections(project) = servers(project).order(:name)

      def connection_for(kind_config, project) = servers(project).find_by(id: kind_config["mcp_server_id"])

      def connection_of(action_call) = action_call.mcp_server

      def awaiting_operations?(kind_config, project)
        servers(project).where(id: kind_config["mcp_server_id"], tool_snapshot_at: nil).exists?
      end

      def operations(server)
        return [] unless server.tool_baseline? && server.tool_schemas_stored?

        Array(server.tool_snapshot["tools"]).sort_by { |tool| tool["name"].to_s }.map do |tool|
          Operation.new(key: tool["name"], name: tool["name"], description: tool["description"],
                        input_schema: tool["input_schema"] || {}, output_schema: nil,
                        base_effect: Actions::Effect.base_for_annotations(tool["annotations"]),
                        drifted: ::MCP::ToolDriftDetector.drifted_tool?(server, tool["name"]))
        end
      end

      def find_operation(server, kind_config) = operations(server).find { |operation| operation.key == kind_config["tool"] }

      def target_attributes(server, operation) = { mcp_server_id: server.id, tool: operation.key }

      def owner(server) = server&.name

      def target_name(_server, operation) = operation.name

      def label(server, operation) = "#{owner(server) || 'the server'} · #{operation.name}"

      def call(connection:, operation:, arguments:, context:)
        result = ::MCP::ToolCaller.call(server: connection, tool: operation.key, arguments: arguments, user: context.user)
        Result.new(**result.to_h)
      end

      private

      def servers(project)
        MCPServer.for_project(project).enabled.unarchived.where(transport: CALLABLE_TRANSPORTS)
      end
    end
  end
end

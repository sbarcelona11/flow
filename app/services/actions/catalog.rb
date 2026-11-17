# frozen_string_literal: true

module Actions
  class Catalog
    Target = Data.define(:type, :mcp_server_id, :server_name, :tool, :tool_id, :api_operation_id, :name, :description,
                         :input_schema, :base_effect, :drifted, :http_method, :path)

    Resolved = Data.define(:transport, :connection, :operation)

    NO_REFERENCES = { mcp_server_id: nil, tool: nil, tool_id: nil, api_operation_id: nil, http_method: nil, path: nil }.freeze

    def initialize(project)
      @project = project
    end

    def targets
      transports.flat_map do |transport|
        transport.connections(@project).flat_map do |connection|
          transport.operations(connection).map { |operation| target_for(transport, connection, operation) }
        end
      end
    end

    def find(kind_config)
      resolved = resolve(kind_config)
      resolved && target_for(resolved.transport, resolved.connection, resolved.operation)
    end

    def resolve(kind_config)
      config = kind_config.to_h
      transport = transport_for(config["target"])
      connection = transport&.connection_for(config, @project)
      operation = connection && transport.find_operation(connection, config)
      operation && Resolved.new(transport, connection, operation)
    end

    def awaiting_tool_list?(kind_config)
      config = kind_config.to_h
      transport = transport_for(config["target"])
      !transport.nil? && transport.awaiting_operations?(config, @project)
    end

    private

    def transports = Connectors::Registry.keys.map { |key| Connectors::Registry.fetch(key).new }

    def transport_for(target)
      Connectors::Registry.for_target(target).new
    rescue Connectors::Registry::Unknown
      nil
    end

    def target_for(transport, connection, operation)
      Target.new(**NO_REFERENCES, **transport.target_attributes(connection, operation),
                 type: transport.class.transport_target, server_name: transport.owner(connection), name: operation.name,
                 description: operation.description, input_schema: operation.input_schema,
                 base_effect: operation.base_effect, drifted: operation.drifted)
    end
  end
end

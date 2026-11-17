# frozen_string_literal: true

module Connectors
  module Transports
    class Rest < Transport
      transport :rest, target: "rest_operation", position: 3

      def connections(project)
        scoped(project).order("api_connectors.name", :name)
      end

      def connection_for(kind_config, project) = scoped(project).find_by(id: kind_config["api_operation_id"])

      def connection_of(action_call) = action_call.api_operation

      def operations(api_operation)
        [ Operation.new(key: api_operation.id.to_s, name: api_operation.name, description: api_operation.description,
                        input_schema: api_operation.input_schema || {}, output_schema: nil,
                        base_effect: Actions::Effect.base_for_operation(api_operation), drifted: false) ]
      end

      def target_attributes(api_operation, _operation)
        { api_operation_id: api_operation.id, http_method: api_operation.http_method, path: api_operation.path }
      end

      def owner(api_operation) = api_operation&.api_connector&.name

      def target_name(api_operation, operation)
        api_operation ? "#{api_operation.http_method} #{api_operation.path}" : operation.name
      end

      def label(api_operation, operation)
        "#{owner(api_operation) || 'the REST connector'} · #{target_name(api_operation, operation)}"
      end

      def scope_of(api_operation) = api_operation.api_connector.scope

      def operation_noun = "operation"

      def config_label(kind_config, project)
        api_operation = project && project_operations(project).find_by(id: kind_config["api_operation_id"])
        api_operation ? label(api_operation, nil) : "the REST operation"
      end

      def call(connection:, operation:, arguments:, context:)
        result = ::Rest::OperationCaller.call(operation: connection, arguments: arguments, project: context.project)
        Result.new(**result.to_h.merge(structured: json_value(result.structured)))
      end

      private

      def json_value(structured)
        case structured
        when nil, Hash, Array then structured
        else JSON.generate(structured)
        end
      end

      def project_operations(project)
        ApiOperation.joins(:api_connector).where(api_connectors: { scope_type: "Project", scope_id: project.id })
      end

      def scoped(project)
        ApiOperation.enabled.joins(:api_connector).merge(ApiConnector.for_project(project).enabled).includes(:api_connector)
      end
    end
  end
end

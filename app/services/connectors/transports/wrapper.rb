# frozen_string_literal: true

module Connectors
  module Transports
    class Wrapper < Transport
      DEADLINE_MARGIN_SECONDS = 120

      transport :wrapper, target: "wrapper", position: 2

      def async? = true

      def connections(project) = Tool.for_project(project).enabled.order(:name)

      def connection_for(kind_config, project) = Tool.for_project(project).enabled.find_by(id: kind_config["tool_id"])

      def connection_of(action_call) = action_call.tool

      def operations(tool)
        [ Operation.new(key: tool.id.to_s, name: tool.display_name.presence || tool.name, description: tool.description,
                        input_schema: tool.input_schema.as_json || {}, output_schema: nil,
                        base_effect: Actions::Effect.base_for_wrapper, drifted: false) ]
      end

      def target_attributes(tool, _operation) = { tool_id: tool.id }

      def owner(_tool) = nil

      def target_name(tool, operation) = tool&.picker_name || operation.name

      def label(tool, operation) = target_name(tool, operation)

      def action_blocker(input_schema)
        return unless input_schema.to_h.fetch("properties", {}).to_h.key?(Actions::TargetCheck::REPOSITORY_PARAMETER)

        "Wrappers that use a repository can't run as actions."
      end

      def call(connection:, operation:, arguments:, context:)
        tool_result = ToolResult.create!(tool: connection, step_run_id: context.step_run_id,
                                         execution_id: ToolResult.generate_id, state: "processing")
        timeout = ContainerStrategies::ToolStrategy::DEFAULT_TIMEOUT
        execution = { parameters: arguments, project: context.project, session: nil, timeout: timeout,
                      tool_result_id: tool_result.id }
        manifest = prepare(connection, execution)
        return not_started(tool_result, "#{manifest.class.name} while preparing #{operation.name}") if manifest.is_a?(StandardError)

        started = connection.start_container_execution(**execution, manifest: manifest,
                                                       workflow_id: "action-step-run-#{context.step_run_id}")
        return not_started(tool_result, "#{operation.name} could not start.") if refused?(started)
        return maybe_started(operation) unless started.is_a?(Hash) && started[:ok]

        Result.new(ok: true, structured: { "tool_result_id" => tool_result.id,
                                           "deadline_seconds" => timeout + DEADLINE_MARGIN_SECONDS })
      rescue StandardError
        maybe_started(operation)
      end

      def status(handle) = ToolResult.find(handle["tool_result_id"]).state

      def finish(handle)
        tool_result = ToolResult.find(handle["tool_result_id"])
        return Result.new(ok: true, structured: payload(tool_result)) if tool_result.state == "completed"

        Result.new(ok: false, unknown: !(tool_result.state == "failed" && tool_result.exit_code.to_i.nonzero?),
                   error: tool_result.error.presence)
      end

      private

      def prepare(tool, execution)
        tool.container_manifest(**execution)
      rescue StandardError => e
        e
      end

      def refused?(started) = started.is_a?(Hash) && !started[:ok] && started[:error_class].nil?

      def not_started(tool_result, message)
        tool_result.update!(state: "failed", error: "The container did not start")
        Result.new(ok: false, error: message)
      end

      def maybe_started(operation)
        Result.new(ok: false, unknown: true, error: "#{operation.name} may have started. Check it before retrying.")
      end

      def payload(tool_result)
        return JSON.parse(read(tool_result.result_data)) if tool_result.result_data

        tool_result.stdout ? read(tool_result.stdout) : ""
      end

      def read(uploaded) = uploaded.open(&:read).to_s.force_encoding(Encoding::UTF_8)
    end
  end
end

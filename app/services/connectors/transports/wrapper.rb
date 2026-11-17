# frozen_string_literal: true

module Connectors
  module Transports
    class Wrapper < Transport
      REPOSITORY_PARAMETER = "repository_id"
      DEADLINE_MARGIN_SECONDS = 120

      transport :wrapper, target: "wrapper", position: 2

      def async? = true

      def connections(project) = Tool.for_project(project).enabled.order(:name)

      def connection_for(kind_config, project) = Tool.for_project(project).enabled.find_by(id: kind_config["tool_id"])

      def connection_of(action_call) = action_call.tool

      def connection_associations = [ :tool ]

      def operations(tool)
        [ Operation.new(key: tool.id.to_s, name: tool.display_name.presence || tool.name, description: tool.description,
                        input_schema: tool.input_schema.as_json || {}, output_schema: nil,
                        base_effect: Actions::Effect.base_for_wrapper, drifted: false) ]
      end

      def target_attributes(tool, _operation) = { tool_id: tool.id }

      def owner(_tool) = nil

      def target_name(tool, operation) = tool&.picker_name || operation.name

      def label(tool, operation) = target_name(tool, operation)

      def scope_of(tool) = tool.scope

      def recorded_name(kind_config, _operation) = kind_config["tool"]

      def config_label(kind_config, project)
        tool = project && Tool.for_project(project).find_by(id: kind_config["tool_id"])
        tool ? tool.picker_name : "the Wrapper"
      end

      def action_blocker(input_schema, arguments = {})
        return unless input_schema.to_h.fetch("properties", {}).to_h.key?(REPOSITORY_PARAMETER) ||
                      arguments.key?(ContainerStrategies::CustomToolStrategy::REPOSITORY_REFERENCE)

        "Wrappers that use a repository can't run as actions."
      end

      def call(connection:, operation:, arguments:, context:)
        name = label(connection, operation)
        timeout = ContainerStrategies::ToolStrategy::DEFAULT_TIMEOUT
        execution = { parameters: arguments, project: context.project, session: nil, timeout: timeout,
                      tool_result_id: context.tool_result_id }
        manifest = prepare(connection, execution)
        return Result.new(error: "#{manifest.class.name} while preparing #{name}") if manifest.is_a?(StandardError)

        started = connection.start_container_execution(**execution, manifest: manifest,
                                                       workflow_id: "action-step-run-#{context.step_run_id}")
        return Result.new(error: "#{name} could not start.") if refused?(started)
        return maybe_started(name) unless started.is_a?(Hash) && started[:ok]

        Result.new(ok: true, structured: { "tool_result_id" => context.tool_result_id,
                                           "deadline_seconds" => timeout + DEADLINE_MARGIN_SECONDS })
      rescue StandardError
        maybe_started(label(connection, operation))
      end

      def status(handle) = ToolResult.find(handle["tool_result_id"]).state

      def finish(handle)
        tool_result = ToolResult.find(handle["tool_result_id"])
        names = Array(tool_result.tool.required_config_items)
        return Result.new(ok: true, structured: payload(tool_result), config_item_names: names) if tool_result.state == "completed"

        exited = tool_result.state == "failed" && tool_result.exit_code.to_i.nonzero?
        Result.new(unknown: !exited, error: exited ? exit_error(tool_result) : stop_reason(tool_result), config_item_names: names)
      end

      private

      def prepare(tool, execution)
        tool.container_manifest(**execution)
      rescue StandardError => e
        e
      end

      # TemporalService answers every Temporalio::Error, a deadline after the server accepted the start included, with
      # ok: false and an error_class. Only a refusal without one is a start that certainly did not happen.
      def refused?(started) = started.is_a?(Hash) && !started[:ok] && started[:error_class].nil?

      def maybe_started(name) = Result.new(unknown: true, error: "#{name} may have started. Check it before retrying.")

      def exit_error(tool_result)
        stderr = tool_result.stderr ? read(tool_result.stderr).scrub.strip : ""
        stderr.presence || tool_result.error.presence || "Exited with code #{tool_result.exit_code}"
      end

      def stop_reason(tool_result)
        tool_result.state == "failed" ? "stopped: #{tool_result.error.presence || 'no exit code'}" : "did not finish in time"
      end

      def payload(tool_result)
        return JSON.parse(read(tool_result.result_data)) if tool_result.result_data

        tool_result.stdout ? read(tool_result.stdout) : ""
      end

      def read(uploaded) = uploaded.open(&:read).to_s.force_encoding(Encoding::UTF_8)
    end
  end
end

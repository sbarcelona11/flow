# frozen_string_literal: true

module Activities
  module Workflow
    class FinishActionActivity < ::Activities::Base
      STDERR_LIMIT = 500
      REDACTED = "[redacted]"

      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        config = input["kind_config"] || step_run.step.kind_config
        tool_result = find_tool_result(step_run, input["tool_result_id"])
        action_call = ActionCall.where(step_run: step_run).order(:id).last

        if input["stopped"] || outcome.terminal?(step_run)
          return close_stopped(step_run, tool_result, action_call, input["stopped"])
        end

        { "outcome" => finish(step_run, config, tool_result, action_call)["outcome"] }
      end

      private

      def outcome = ::Actions::StepRunOutcome

      def find_tool_result(step_run, id)
        id ? ToolResult.find_by!(id: id, step_run: step_run) : ToolResult.where(step_run: step_run).order(:id).last
      end

      # The step ended while the Wrapper ran: its result no longer becomes the
      # step's, but the call is closed so it never reads as still running.
      def close_stopped(step_run, tool_result, action_call, stopped)
        step_run.with_lock do
          state = outcome.terminal?(step_run) ? step_run.state.to_s : stopped
          close_call(action_call, tool_result, state) if action_call && action_call.outcome.nil?
          { "outcome" => state }
        end
      end

      def close_call(action_call, tool_result, state)
        return action_call.finish!(outcome: "succeeded") if tool_result&.state == "completed"

        label = tool_result ? tool_result.tool.display_name.presence || tool_result.tool.name : "the Wrapper"
        action_call.finish!(outcome: "unknown",
                            error: "The step ended as #{state} while #{label} ran. #{outcome.unknown_advice(label)}")
      end

      def finish(step_run, config, tool_result, action_call)
        return step_run.with_lock { outcome.fail!(step_run, :action_failed, "The Wrapper never started.") } unless tool_result && action_call

        label = tool_result.tool.display_name.presence || tool_result.tool.name
        return succeed(step_run, config, tool_result, action_call, label) if tool_result.state == "completed"

        call_outcome, category, message = failure(step_run, tool_result, label)
        step_run.with_lock do
          action_call.finish!(outcome: call_outcome, error: message) if action_call.outcome.nil?
          outcome.fail!(step_run, category, message)
        end
      end

      def succeed(step_run, config, tool_result, action_call, label)
        outcome.complete!(step_run, action_call, config, payload(tool_result)) do |call|
          "Called #{label} (#{config['effect']}) in #{tool_result.duration_ms || call.duration_ms} ms"
        end
      end

      def payload(tool_result)
        return JSON.parse(read(tool_result.result_data)) if tool_result.result_data

        tool_result.stdout ? read(tool_result.stdout) : ""
      end

      def read(uploaded) = uploaded.open(&:read).to_s.force_encoding(Encoding::UTF_8)

      def failure(step_run, tool_result, label)
        if tool_result.state == "failed" && tool_result.exit_code.to_i.nonzero?
          return [ "failed", :action_failed, failure_message(step_run, tool_result) ]
        end

        reason = tool_result.state == "failed" ? "stopped: #{tool_result.error.presence || 'no exit code'}" : "did not finish in time"
        [ "unknown", :action_outcome_unknown,
          "#{label} #{redact(step_run, tool_result, reason.truncate(STDERR_LIMIT))}. #{outcome.unknown_advice(label)}" ]
      end

      def failure_message(step_run, tool_result)
        stderr = tool_result.stderr ? read(tool_result.stderr).scrub.strip : ""
        text = stderr.presence || tool_result.error.presence || "Exited with code #{tool_result.exit_code}"
        redact(step_run, tool_result, text)[0, STDERR_LIMIT]
      end

      # The Wrapper's config items reach its container as environment
      # variables, so its own output may print them.
      def redact(step_run, tool_result, text)
        names = Array(tool_result.tool.required_config_items)
        project = step_run.workflow_run.project
        return text if names.empty? || project.nil?

        values = ConfigItem.where(name: names, scope: [ project, project.company ]).filter_map(&:decrypted_value)
        values.select { |value| value.length >= 4 }.sort_by { |value| -value.length }
              .reduce(text) { |scrubbed, value| scrubbed.gsub(value, REDACTED) }
      end
    end
  end
end

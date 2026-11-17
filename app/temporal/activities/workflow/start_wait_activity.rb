# frozen_string_literal: true

module Activities
  module Workflow
    class StartWaitActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        config = input["kind_config"] || step_run.step.kind_config

        ended = step_run.with_lock do
          next true if step_run.completed? || step_run.failed? || step_run.skipped? || step_run.cancelled?

          step_run.mark_running! if step_run.pending?
          false
        end
        return already_ended(step_run) if ended

        wait_seconds(step_run, config)
      end

      private

      def wait_seconds(step_run, config)
        return { "seconds" => config["delay_seconds"] } if config["delay_seconds"].is_a?(Integer)

        key = config["until_context_key"]
        return fail_wait(step_run, "Wait step has neither a delay nor a shared context key") unless key.is_a?(String)

        time = parse_time(step_run.workflow_run.shared_context&.dig(*key.split(".")))
        return fail_wait(step_run, "Wait time not found: no ISO 8601 time at shared context key `#{key}`") unless time

        seconds = [ (time - Time.current).ceil, 0 ].max
        if seconds > Step::CONTROL_STEP_MAX_SECONDS
          return fail_wait(step_run, "Wait time at shared context key `#{key}` is more than 6 days away")
        end

        { "seconds" => seconds }
      end

      def fail_wait(step_run, message)
        step_run.mark_failed!(message, error_category: :wait_invalid_time)
        { "error" => message }
      end

      def already_ended(step_run)
        return { "seconds" => 0 } unless step_run.failed?

        { "error" => step_run.error_message.presence || "Step run is already failed" }
      end

      def parse_time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end
    end
  end
end

# frozen_string_literal: true

module Activities
  module Workflow
    class StartWaitActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        return already_ended(step_run) if step_run.completed? || step_run.failed? || step_run.skipped? || step_run.cancelled?

        step_run.mark_running! unless step_run.running?
        config = step_run.step.kind_config

        return { "seconds" => config["delay_seconds"] } if config["delay_seconds"]

        key = config["until_context_key"]
        time = parse_time(step_run.workflow_run.shared_context&.dig(*key.split(".")))
        return { "seconds" => [ (time - Time.current).ceil, 0 ].max } if time

        message = "Wait time not found: no ISO 8601 time at shared context key `#{key}`"
        step_run.mark_failed!(message, error_category: :wait_invalid_time)
        { "error" => message }
      end

      private

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

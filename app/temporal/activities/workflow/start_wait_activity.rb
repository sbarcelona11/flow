# frozen_string_literal: true

module Activities
  module Workflow
    class StartWaitActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        step_run.mark_running!
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

      def parse_time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end
    end
  end
end

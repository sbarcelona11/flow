# frozen_string_literal: true

module Activities
  module Workflow
    class OpenApprovalActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        config = input["kind_config"] || step_run.step.kind_config
        timeout = config["timeout_seconds"]
        return invalid_timeout(step_run) unless timeout.is_a?(Integer) && timeout.positive?

        step_run.with_lock { step_run.mark_awaiting_approval! if step_run.pending? }

        { "timeout_seconds" => timeout, "on_timeout" => config["on_timeout"] }
      end

      private

      def invalid_timeout(step_run)
        message = "Approval step has no valid timeout"
        step_run.with_lock do
          step_run.mark_failed!(message, error_category: :approval_invalid_config) if step_run.pending? || step_run.waiting_input?
        end
        { "error" => message }
      end
    end
  end
end

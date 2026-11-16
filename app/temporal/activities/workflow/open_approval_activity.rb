# frozen_string_literal: true

module Activities
  module Workflow
    class OpenApprovalActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        step_run.mark_awaiting_approval!
        config = step_run.step.kind_config

        { "timeout_seconds" => config["timeout_seconds"], "on_timeout" => config["on_timeout"] }
      end
    end
  end
end

# frozen_string_literal: true

module Activities
  module Workflow
    class FinishActionActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        ::Actions::Pipeline.finish(step_run: step_run, handle: { "tool_result_id" => input["tool_result_id"] },
                                   stopped: input["stopped"], kind_config: input["kind_config"] || step_run.step.kind_config)
      end
    end
  end
end

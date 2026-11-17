# frozen_string_literal: true

module Activities
  module Workflow
    class StartActionActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        ::Actions::Pipeline.start(step_run: step_run, kind_config: input["kind_config"] || step_run.step.kind_config,
                                  depends_on_step_ids: input["depends_on_step_ids"] || step_run.step.depends_on_step_ids)
      end
    end
  end
end

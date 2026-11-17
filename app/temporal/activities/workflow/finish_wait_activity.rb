# frozen_string_literal: true

module Activities
  module Workflow
    class FinishWaitActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        step_run.with_lock do
          step_run.mark_completed! if step_run.running? || step_run.waiting_input? || step_run.pending?
        end

        { "ok" => true, "state" => step_run.state.to_s }
      end
    end
  end
end

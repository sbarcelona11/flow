# frozen_string_literal: true

module Activities
  module Workflow
    class ExpireApprovalActivity < ::Activities::Base
      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        config = input["kind_config"] || step_run.step.kind_config

        step_run.with_lock do
          expire(step_run, config) if step_run.pending? || step_run.waiting_input?
        end

        { "outcome" => step_run.state.to_s }
      end

      private

      def expire(step_run, config)
        message = "No one approved within #{waited(config['timeout_seconds'].to_i)}"

        if config["on_timeout"] == "skip"
          step_run.mark_skipped!(message)
        else
          step_run.mark_failed!(message, error_category: :approval_timeout)
        end
      end

      def waited(seconds)
        seconds >= 3600 ? "#{seconds / 3600} h" : "#{seconds / 60} min"
      end
    end
  end
end

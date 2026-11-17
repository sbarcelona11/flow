# frozen_string_literal: true

module Actions
  # A `send` or `irreversible` action runs only after an approval step: one of
  # its direct dependencies must be an approval step of the same workflow (D4).
  #
  # Checked over the whole workflow, not per step, because every bulk writer
  # (WorkflowStepSync, the template installer, the duplicator) saves steps first
  # and wires their dependencies after; and because removing or retyping the
  # approval step breaks the rule without touching the action. Versions runs it
  # on every workflow write (Versions::WritePathCoverageTest keeps them there).
  module Governance
    NAMED = { "send" => "A send action", "irreversible" => "An irreversible action" }.freeze

    module_function

    def verify!(workflow)
      steps = Step.where(workflow_id: workflow.id).not_deleted.to_a
      approvals = steps.select { |step| blocking_approval?(step) }.to_set(&:id)
      offender = steps.find do |step|
        step.action? && Effect.needs_approval?(step.kind_config["effect"]) &&
          step.depends_on_step_ids.none? { |id| approvals.include?(id) }
      end
      return nil unless offender

      offender.errors.add(:base, message(offender.kind_config["effect"]))
      raise ActiveRecord::RecordInvalid, offender
    end

    # A skipped step counts as done for the steps after it, so an approval that
    # is skipped on timeout or on rejection would let the action run unapproved.
    def blocking_approval?(step)
      step.kind_approval? && step.kind_config["on_timeout"] == "fail" && step.on_failure.to_s == "fail"
    end

    def message(effect) = "#{NAMED.fetch(effect)} must run after an approval step that stops the run when no one approves."
  end
end

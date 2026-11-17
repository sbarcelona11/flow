# frozen_string_literal: true

module Actions
  # An action's `{{output:<step>:<name>}}` arguments must read a file an earlier step declares, or the run would only
  # find out when the step starts. Checked over the whole workflow like Governance, because every bulk writer saves
  # steps first and wires their dependencies after, and because removing a step or a dependency breaks the rule without
  # touching the action. Versions runs it on every workflow write.
  module OutputReferences
    module_function

    def verify!(workflow)
      return nil unless Step.where(workflow_id: workflow.id, kind: "action").not_deleted.exists?

      project = workflow.scope if workflow.scope_type == "Project"
      issue = DataFlow::Check.for_workflow(workflow, project: project).argument_issues.first
      return nil unless issue

      offender = Step.find_by!(id: issue.step_key, workflow_id: workflow.id)
      offender.errors.add(:base, issue.message)
      raise ActiveRecord::RecordInvalid, offender
    end
  end
end

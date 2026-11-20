# frozen_string_literal: true

module PersonalTools
  class AddBlockStep < Base
    include RestAuthoring

    tool do
      display_name "Add Block Step"
      description "Add a block to a workflow. An action block becomes one action step; a composite block is expanded into its " \
                  "ordinary steps. Only a block a person has approved and enabled can be used: a block that is waiting for " \
                  "review, switched off, rejected or archived is refused. For an action block `bindings` are its settings; " \
                  "for a composite they are its in ports (text, or {{output:<step id>:<file>}}). Everything is saved as one " \
                  "new workflow version, and the workflow's own checks apply (a send or irreversible action needs an " \
                  "approval step before it); if any check fails nothing is added."
      audience :user
      strict
      tags :rest_authoring
      param :project_id, type: :integer, description: "Project id.", required: true
      param :workflow_id, type: :integer, description: "Workflow id.", required: true
      param :ref, type: :string, description: "The block, as namespace/slug@version (see list_blocks).", required: true
      param :bindings, type: :object, description: "Settings (action block) or in-port values (composite). Never a secret."
      param :base_version, type: :integer, required: true,
                           description: "The workflow version you read (current_version_number). A newer one means someone else saved since, and nothing is added."
    end

    def execute
      project = authoring_project!(Web::Company::Projects::WorkflowsPolicy, :update?)
      return error("Too many blocks added. Try again in a minute.") if throttled?("personal_tools/add_block_step", 20)

      workflow = find_workflow!(project)
      return error("base_version is required: read the workflow first (get_workflow, current_version_number).") if base_version.nil?

      bindings = hash_param(:bindings)
      checked_text(bindings, "a binding")
      result = nil
      Versions.save!(workflow, actor: version_actor, base_version: base_version) do
        result = Modules::BlockInsertion.call(project: project, workflow: workflow, ref: params[:ref], bindings: bindings)
      end
      success(payload(workflow.reload, result))
    rescue RestAuthoring::InvalidInput => e
      error(e.message)
    rescue Modules::BlockInsertion::Refused => e
      error(Authoring::ToolText.quoted("Nothing was added", e.message, max: 400))
    rescue ActiveRecord::RecordNotFound => e
      error(Authoring::ToolText.quoted("Not found", e.message, max: 200))
    rescue ActiveRecord::RecordInvalid => e
      error(Authoring::ToolText.quoted("Nothing was added, the workflow refused it", e.message, max: 600))
    end

    private

    def payload(workflow, result)
      { notice: Authoring::ToolText::NOTICE, id: result.steps.first&.id, workflow_id: workflow.id, current_version_number: workflow.current_version_number,
        steps: result.steps.map { |step| { id: step.id, name: untrusted(step.name, max: 120), kind: step.kind.to_s, position: step.position } },
        step_ids: result.steps.map(&:id), unbound_ports: result.unbound, warnings: untrusted_lines(result.warnings, max: 300) }
    end
  end
end

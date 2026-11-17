# frozen_string_literal: true

# The props of the project's workflow list page, shared by the Workflows list and
# the Automations entry, which renders the same page.
module WorkflowListProps
  extend ActiveSupport::Concern
  include RunnerOptions

  private

  def workflow_list_props
    workflows = Workflow.attach_run_stats(
      Workflow.visible_for_project(current_project).includes(:base_resource_links, steps: %i[sub_steps resource_links])
    )
    archived = Workflow.for_project(current_project).where.not(deleted_at: nil).order(deleted_at: :desc)

    {
      project: project_props,
      workflows: workflows.map { |w|
        WorkflowResource.new(w).to_h.merge(
          steps: w.visible_steps.map { |s| StepResource.new(s).to_h }
        )
      },
      archived_workflows: archived.map { |w| { id: w.id, name: w.name, archived_at: w.deleted_at } },
      configured_agents: current_project_membership&.configured_agents || [],
      default_agent_runtime: current_project_membership&.default_agent_runtime,
      # Company-scoped assets are shared with every project in the company and are
      # already offered by the assets page, the session form and the Aixle Builder.
      # `current_project.assets` walks the has_many and sees project-owned rows only,
      # so the workflow builder was the one picker that could not reach them.
      assets: InertiaRails.defer(group: "resources") {
        Asset.accessible_from_project(current_project).map { |r| AssetPickerResource.new(r).to_h }
      },
      repositories: InertiaRails.defer(group: "resources") {
        Repository.visible_for_project(current_project).map { |r| PickerResource.new(r).to_h }
      },
      # Names and types only — a config item's value never reaches a prop.
      config_items: InertiaRails.defer(group: "resources") {
        ConfigItem.visible_for_project(current_project).map { |r| ConfigItemPickerResource.new(r).to_h }
      },
      agent_models: InertiaRails.defer(group: "resources") {
        current_project_membership&.agent_models_for_props || []
      },
      runners: InertiaRails.defer(group: "resources") { runner_options }
    }
  end
end

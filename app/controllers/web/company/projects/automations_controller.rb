# frozen_string_literal: true

class Web::Company::Projects::AutomationsController < Web::Company::Projects::ApplicationController
  include WorkflowListProps

  requires_feature :automations_canvas

  def index
    render inertia: "Projects/Workflows/WorkflowsPage", props: workflow_list_props.merge(surface: "automations")
  end
end

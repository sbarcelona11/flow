# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::AutomationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:automations_canvas, true, company: @company, &block)

  test "index is not found while the flag is off" do
    get company_project_automations_path(@project)

    assert_response :not_found
  end

  test "index is not found when the flag is on for another company only" do
    with_feature(:automations_canvas, true, company: create(:company)) do
      get company_project_automations_path(@project)
    end

    assert_response :not_found
  end

  test "index renders the workflows page for the automations surface" do
    workflow = create(:workflow, scope: @project)

    enabled { get company_project_automations_path(@project) }

    assert_inertia_page "Projects/Workflows/WorkflowsPage"
    assert_inertia_props(surface: "automations")
    assert_inertia_props do |props|
      assert_equal [ workflow.id ], props[:workflows].map { |w| w[:id] }
    end
  end

  test "index carries the list page's props" do
    enabled { get company_project_automations_path(@project) }

    assert_inertia_props do |props|
      assert_equal @project.id, props[:project][:id]
      assert_equal [], props[:archivedWorkflows]
      assert props.key?(:configuredAgents)
    end
  end
end

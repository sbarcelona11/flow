# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ModuleDefinitionsFromStepsTest < ActionDispatch::IntegrationTest
  include CompositeHelper

  setup do
    build_composite_project
    build_pipeline
    sign_in_as(@user)
  end

  def save_block(ids = [ @summarise.id, @approve.id, @send.id ], project: @project, workflow: @workflow, **params)
    post from_steps_company_project_module_definitions_path(project), params: { workflow_id: workflow.id, step_ids: ids, label: "Invoice flow", **params }, as: :json
  end

  test "Save as block creates a reviewed, enabled composite and the expansion round-trips" do
    save_block

    assert_response :created
    definition = ModuleDefinition.find(response.parsed_body["id"])
    assert_equal [ "web", true, @user.id ], [ definition.origin, definition.reviewed?, definition.reviewed_by_id ]
    assert definition.enabled?
    assert_equal "composite", definition.manifest["executor"]
    assert_equal "valid", response.parsed_body["status"]
    assert_equal [ "local/invoice-flow@1" ], Modules::Registry.new(@project).blocks.select { |b| b.executor == "composite" }.map(&:key)
  end

  test "an ambiguous or ungoverned selection is a 422 with a clear message and creates nothing" do
    assert_no_difference "ModuleDefinition.count" do
      save_block([ @summarise.id, @send.id ])
    end

    assert_response :unprocessable_entity
    assert_equal "Include the approval step Approve in the block: Send invoice (send) must run after it.", response.parsed_body["error"]
  end

  test "a workflow of another project is not found" do
    other = create(:project, company: @company, owner: @user)
    foreign = create(:workflow, scope: other)

    assert_no_difference "ModuleDefinition.count" do
      save_block([ @fetch.id ], workflow: foreign)
    end

    assert_response :not_found
  end

  test "it needs the canvas flag" do
    FeatureFlag.find_by!(key: "automations_canvas").overrides.update_all(enabled: false)
    Current.feature_snapshot = nil

    save_block([ @fetch.id ])

    assert_response :not_found
  end
end

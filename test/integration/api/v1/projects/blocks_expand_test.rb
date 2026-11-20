# frozen_string_literal: true

require "test_helper"

class Api::V1::Projects::BlocksExpandTest < ActionDispatch::IntegrationTest
  include CompositeHelper

  setup do
    build_composite_project
    build_pipeline
    stamp_composite(Modules::Composite::Extractor.new(workflow: @workflow, step_ids: [ @summarise.id, @approve.id, @send.id ],
                                                      label: "Invoice flow").manifest.manifest)
    @target = create(:workflow, scope: @project, name: "Target")
    sign_in_as(@user)
  end

  def expand(project: @project, **params)
    post expand_api_v1_project_blocks_path(project), params: { ref: "local/invoice-flow@1", **params }, as: :json
  end

  test "expands a composite into draft steps without saving anything" do
    assert_no_difference "Step.count" do
      expand(bindings: { fetch_invoice_invoice: "{{output:#{@fetch.id}:invoice.json}}" }, first_index: 2, workflow_id: @target.id)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal %w[new-2 new-3 new-4], body["steps"].pluck("key")
    assert_equal [ @fetch.id ], body["steps"].first["depends_on_step_ids"]
    assert_equal "summarise", body["steps"].first.dig("composite", "node")
    assert_match(/\A\h{8}-/, body["instance"])
  end

  test "a missing or foreign block is 404 and an unusable request is 422" do
    expand(ref: "local/ghost@1")
    assert_response :not_found

    other = create(:project, company: @company, owner: @user)
    enable_company_feature(:workflow_action_steps, @company)
    expand(project: other)
    assert_response :not_found

    expand(bindings: { nope: "x" })
    assert_response :unprocessable_entity
  end

  test "a disabled block is 404" do
    ModuleDefinition.find_by!(slug: "invoice-flow").update!(enabled: false)

    expand

    assert_response :not_found
  end

  test "it needs the action steps flag" do
    FeatureFlag.find_by!(key: "workflow_action_steps").overrides.update_all(enabled: false)
    Current.feature_snapshot = nil

    expand

    assert_response :not_found
  end
end

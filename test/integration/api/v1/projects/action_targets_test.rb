# frozen_string_literal: true

require "test_helper"

class Api::V1::Projects::ActionTargetsTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @owner = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @owner)
    sign_in_as(@owner)
  end

  test "lists action targets" do
    schema = { "type" => "object", "properties" => { "due_date" => { "type" => "string" } } }
    server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing",
                                 snapshot_tools: [ { "name" => "search", "description" => "Find", "input_schema" => schema,
                                                     "annotations" => { "readOnlyHint" => true } } ])
    server.update!(tool_drift: { "changed" => [ "search" ] })
    wrapper = create(:tool, scope: @project, display_name: "Invoice lines")
    operation = create(:api_operation, api_connector: create(:api_connector, scope: @project, name: "Payments"),
                                       name: "list_charges")

    with_feature(:workflow_action_steps, true, company: @company) do
      get api_v1_project_action_targets_path(@project), as: :json
    end

    assert_response :success
    mcp, wrapper_target, rest = response.parsed_body
    assert_equal({ "type" => "mcp_tool", "mcpServerId" => server.id, "serverName" => "Billing", "tool" => "search",
                   "toolId" => nil, "apiOperationId" => nil, "name" => "search", "description" => "Find", "inputSchema" => schema,
                   "baseEffect" => "read", "drifted" => true, "httpMethod" => nil, "path" => nil }, mcp.except("_preserveKeys"))
    assert_equal [ "wrapper", wrapper.id, "Invoice lines", "write" ],
                 wrapper_target.values_at("type", "toolId", "name", "baseEffect")
    assert_equal [ "rest_operation", operation.id, "Payments", "list_charges", "read", "GET", operation.path ],
                 rest.values_at("type", "apiOperationId", "serverName", "name", "baseEffect", "httpMethod", "path")
  end

  test "404 when workflow_action_steps is off" do
    get api_v1_project_action_targets_path(@project), as: :json

    assert_response :not_found
  end
end

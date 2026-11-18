# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ApiOperationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    @connector = create(:api_connector, scope: @project)
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  test "create adds an operation with its schema" do
    schema = { type: "object", properties: { path: { type: "object", properties: { id: { type: "string" } }, required: [ "id" ] } } }

    enabled do
      post company_project_api_connector_api_operations_path(@project, @connector), params: {
        api_operation: { name: "get_thing", http_method: "GET", path: "/things/{id}", effect: "read", input_schema: schema }
      }, as: :json
    end

    assert_redirected_to edit_company_project_api_connector_path(@project, @connector)
    operation = @connector.api_operations.find_by!(name: "get_thing")
    assert_equal [ "id" ], operation.input_schema.dig("properties", "path", "required")
  end

  test "create keeps the schema's property names as written" do
    schema = { type: "object", properties: { query: { type: "object", properties: { pageSize: { type: "integer" } } } } }

    enabled do
      post company_project_api_connector_api_operations_path(@project, @connector), params: {
        api_operation: { name: "list_things", http_method: "GET", path: "/things", effect: "read", input_schema: schema }
      }, as: :json
    end

    assert_equal [ "pageSize" ], @connector.api_operations.find_by!(name: "list_things").input_schema.dig("properties", "query", "properties").keys
  end

  test "create still accepts the method under its old name" do
    enabled do
      post company_project_api_connector_api_operations_path(@project, @connector), params: {
        api_operation: { name: "make_thing", method: "POST", path: "/things", effect: "write" }
      }, as: :json
    end

    assert_equal "POST", @connector.api_operations.find_by!(name: "make_thing").http_method
  end

  test "create refuses an effect below the method's minimum" do
    enabled do
      post company_project_api_connector_api_operations_path(@project, @connector), params: {
        api_operation: { name: "make_thing", http_method: "POST", path: "/things", effect: "read" }
      }
    end

    assert_nil @connector.api_operations.find_by(name: "make_thing")
  end

  test "update edits an operation" do
    operation = create(:api_operation, api_connector: @connector)

    enabled do
      patch company_project_api_connector_api_operation_path(@project, @connector, operation),
            params: { api_operation: { summary: "Lists things", enabled: false } }
    end

    assert_equal "Lists things", operation.reload.summary
    assert_not operation.enabled
  end

  test "create and update store the cost per call; a missing key keeps it and an explicit null clears it" do
    enabled do
      post company_project_api_connector_api_operations_path(@project, @connector), params: {
        api_operation: { name: "make_thing", http_method: "POST", path: "/things", effect: "write", cost_cents: 40 }
      }, as: :json
    end
    operation = @connector.api_operations.find_by!(name: "make_thing")
    assert_equal 40, operation.cost_cents

    enabled { patch company_project_api_connector_api_operation_path(@project, @connector, operation), params: { api_operation: { summary: "x" } }, as: :json }
    assert_equal 40, operation.reload.cost_cents

    enabled { patch company_project_api_connector_api_operation_path(@project, @connector, operation), params: { api_operation: { cost_cents: nil } }, as: :json }
    assert_nil operation.reload.cost_cents
  end

  test "update refuses a cost that is malformed or out of range instead of clearing it" do
    operation = create(:api_operation, api_connector: @connector, cost_cents: 40)

    [ -1, 1_000_001, 1.5, "", "abc", false, [ 5 ], { a: 1 } ].each do |bad|
      enabled do
        patch company_project_api_connector_api_operation_path(@project, @connector, operation),
              params: { api_operation: { cost_cents: bad } }, as: :json
      end

      assert_equal 40, operation.reload.cost_cents, bad.inspect
    end
  end

  test "destroy deletes an unused operation" do
    operation = create(:api_operation, api_connector: @connector)

    enabled { delete company_project_api_connector_api_operation_path(@project, @connector, operation) }

    assert_nil ApiOperation.find_by(id: operation.id)
  end

  test "destroy refuses an operation a saved action step uses" do
    operation = create(:api_operation, api_connector: @connector)
    workflow = create(:workflow, scope: @project)
    with_feature(:workflow_action_steps, true, company: @company) do
      create(:step, workflow: workflow, kind: "action", kind_config: {
        "target" => "rest_operation", "api_operation_id" => operation.id, "effect" => "read",
        "arguments" => {}, "output_name" => "out.json"
      })
    end

    enabled { delete company_project_api_connector_api_operation_path(@project, @connector, operation) }

    assert ApiOperation.exists?(operation.id)
    assert_equal "This operation is used by 1 action step(s). Disable it instead.", flash[:alert]
  end

  test "404 when the flag is off" do
    post company_project_api_connector_api_operations_path(@project, @connector), params: { api_operation: { name: "x" } }
    assert_response :not_found
  end

  test "a viewer cannot create" do
    viewer = create(:user, :onboarding_completed, company: @company, membership_role: :viewer, password: AuthHelper::TEST_PASSWORD)
    @project.add_collaborator(viewer)
    sign_in_as(viewer)

    enabled do
      post company_project_api_connector_api_operations_path(@project, @connector),
           params: { api_operation: { name: "x_op", http_method: "GET", path: "/x", effect: "read" } }
    end

    assert_nil @connector.api_operations.find_by(name: "x_op")
  end
end

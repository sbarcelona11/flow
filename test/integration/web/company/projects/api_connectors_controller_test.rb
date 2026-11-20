# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ApiConnectorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  test "index sends the names of the project's Config Items, ordered, and never a value" do
    create(:config_item, scope: @project, name: "ZED_KEY", item_type: :secret, value: "zed-secret-value")
    create(:config_item, scope: @project, name: "ALPHA_TOKEN", item_type: :secret, value: "alpha-secret-value")
    create(:config_item, scope: create(:project, company: @company, owner: @user), name: "OTHER_PROJECT_KEY")

    enabled { get company_project_api_connectors_path(@project) }

    assert_inertia_props do |props|
      (props[:configItemNames] || props[:config_item_names]) == %w[ALPHA_TOKEN ZED_KEY]
    end
    assert_not_includes response.body, "alpha-secret-value"
    assert_not_includes response.body, "zed-secret-value"
  end

  test "index lists connectors with their operation counts and archived ones apart" do
    connector = create(:api_connector, :bearer, scope: @project)
    create(:api_operation, api_connector: connector)
    create(:api_connector, scope: @project, archived_at: Time.current)

    enabled { get company_project_api_connectors_path(@project) }

    assert_inertia_page "Projects/ApiConnectors/ApiConnectorsPage"
    assert_inertia_props do |props|
      listed = props[:apiConnectors] || props[:api_connectors]
      listed.size == 1 && listed.first[:operationsCount] == 1 &&
        listed.first[:authConfig]["config_item_name"] == "EXAMPLE_TOKEN" &&
        (props[:archivedConnectors] || props[:archived_connectors]).size == 1
    end
  end

  test "new renders the form" do
    enabled { get new_company_project_api_connector_path(@project) }
    assert_inertia_page "Projects/ApiConnectors/ApiConnectorPage"
  end

  test "create saves a connector in the project" do
    enabled do
      post company_project_api_connectors_path(@project), params: {
        api_connector: { name: "billing", base_url: "https://api.example.com/v1/", auth_type: "bearer",
                         auth_config: { config_item_name: "BILLING_TOKEN" }, default_headers: { "Accept" => "application/json" } }
      }
    end

    connector = ApiConnector.find_by!(name: "billing")
    assert_redirected_to edit_company_project_api_connector_path(@project, connector)
    assert_equal @project.id, connector.scope_id
    assert_equal({ "config_item_name" => "BILLING_TOKEN" }, connector.auth_config)
  end

  test "create with an invalid connector saves nothing" do
    enabled do
      post company_project_api_connectors_path(@project), params: { api_connector: { name: "bad", base_url: "http://insecure.example.com" } }
    end

    assert_response :redirect
    assert_nil ApiConnector.find_by(name: "bad")
  end

  test "edit renders the connector with its operations" do
    connector = create(:api_connector, scope: @project)
    create(:api_operation, api_connector: connector, name: "list_things", input_schema: { "type" => "object", "properties" => { "query" => { "type" => "object", "properties" => { "page_size" => { "type" => "integer" } } } } })

    enabled { get edit_company_project_api_connector_path(@project, connector) }

    assert_inertia_page "Projects/ApiConnectors/ApiConnectorPage"
    assert_inertia_props do |props|
      operation = props[:operations].first
      operation["name"] == "list_things" && operation["minimumEffect"] == "read" &&
        operation["inputSchema"]["properties"]["query"]["properties"].key?("page_size")
    end
  end

  test "update changes the connector" do
    connector = create(:api_connector, scope: @project)

    enabled { patch company_project_api_connector_path(@project, connector), params: { api_connector: { description: "Billing API", enabled: false } } }

    assert_redirected_to edit_company_project_api_connector_path(@project, connector)
    assert_equal "Billing API", connector.reload.description
    assert_not connector.enabled
  end

  test "archive and unarchive" do
    connector = create(:api_connector, scope: @project)

    enabled { post archive_company_project_api_connector_path(@project, connector) }
    assert connector.reload.archived?

    enabled { post unarchive_company_project_api_connector_path(@project, connector) }
    assert_not connector.reload.archived?
  end

  test "a connector of another project is not found" do
    other = create(:api_connector, scope: create(:project, company: @company, owner: @user))

    enabled { get edit_company_project_api_connector_path(@project, other) }

    assert_response :not_found
  end

  test "a viewer cannot create" do
    viewer = create(:user, :onboarding_completed, company: @company, membership_role: :viewer, password: AuthHelper::TEST_PASSWORD)
    @project.add_collaborator(viewer)
    sign_in_as(viewer)

    enabled do
      post company_project_api_connectors_path(@project), params: { api_connector: { name: "x", base_url: "https://a.example.com" } }
    end

    assert_nil ApiConnector.find_by(name: "x")
  end

  test "404 when the flag is off" do
    get company_project_api_connectors_path(@project)
    assert_response :not_found
  end

  test "create stamps the connector as created and reviewed by the signed-in person" do
    enabled do
      post company_project_api_connectors_path(@project), params: { api_connector: { name: "billing", base_url: "https://api.example.com/v1" } }
    end

    connector = ApiConnector.find_by!(name: "billing")
    assert_equal "web", connector.origin
    assert_equal @user, connector.created_by
    assert_equal @user, connector.reviewed_by
    assert_not_nil connector.reviewed_at
    assert connector.enabled
  end

  test "update keeps the original review stamp" do
    connector = create(:api_connector, scope: @project)
    stamped_at = connector.reviewed_at

    enabled { patch company_project_api_connector_path(@project, connector), params: { api_connector: { description: "Billing" } } }

    assert_equal stamped_at, connector.reload.reviewed_at
  end

  test "the connector props expose origin and review state" do
    create(:api_connector, scope: @project)

    enabled { get company_project_api_connectors_path(@project) }

    assert_inertia_props do |props|
      listed = (props[:apiConnectors] || props[:api_connectors]).first
      listed[:origin] == "web" && (listed[:reviewState] || listed[:review_state]) == "reviewed"
    end
  end

  test "update refuses to enable a connector that is waiting for review and says so" do
    connector = create(:api_connector, :proposed, scope: @project)

    enabled { patch company_project_api_connector_path(@project, connector), params: { api_connector: { enabled: true } } }

    assert_redirected_to edit_company_project_api_connector_path(@project, connector)
    assert_nil flash[:notice]
    assert_equal false, connector.reload.enabled # rubocop:disable Minitest/RefuteFalse
    assert_nil connector.reviewed_at
  end
end

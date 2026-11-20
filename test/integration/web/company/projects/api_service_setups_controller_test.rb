# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ApiServiceSetupsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  def json = response.parsed_body

  def payload(**overrides)
    { connector: { name: "billing", baseUrl: "https://api.example.com/v1", authType: "none", defaultHeaders: { "X-Tenant-Id" => "acme" } },
      operations: [ { name: "list_invoices", httpMethod: "GET", path: "/invoices", summary: "List invoices", effect: "read",
                      label: "List invoices",
                      inputSchema: { type: "object", properties: { query: { type: "object", properties: { pageSize: { type: "integer" } } } } } } ] }.merge(overrides)
  end

  def create_service(body = payload) = enabled { post company_project_api_service_setups_path(@project), params: body, as: :json }

  test "creates the connector, operations and blocks, stamped as reviewed by the signed-in person" do
    create_service

    assert_response :created
    connector = ApiConnector.find(json.dig("connector", "id"))
    assert_equal edit_company_project_api_connector_path(@project, connector), json.dig("connector", "editPath")
    assert_equal [ @project, "web", @user, "reviewed", true ],
                 [ connector.scope, connector.origin, connector.reviewed_by, connector.review_state, connector.enabled ]
    assert_equal({ "X-Tenant-Id" => "acme" }, connector.default_headers)
    operation = connector.api_operations.sole
    assert_equal [ "reviewed", @user ], [ operation.review_state, operation.reviewed_by ]
    assert_equal [ "pageSize" ], operation.input_schema.dig("properties", "query", "properties").keys
    block = ModuleDefinition.find(json["blocks"].sole["id"])
    assert_equal [ "reviewed", "local/list-invoices@1", true ], [ block.review_state, json["blocks"].sole["key"], block.enabled ]
    assert_equal [ operation.id ], json["operations"].pluck("id")
    assert_kind_of Array, json["warnings"]
  end

  test "blocks: false creates none" do
    create_service(payload(blocks: false))

    assert_response :created
    assert_empty json["blocks"]
    assert_equal 0, ModuleDefinition.count
  end

  test "an invalid operation answers 422 with the errors and creates nothing" do
    body = payload
    body[:operations] << { name: "bad name", httpMethod: "GET", path: "nope", effect: "read" }

    create_service(body)

    assert_response :unprocessable_content
    assert json["errors"].key?("operations.1")
    assert_equal [ 0, 0, 0 ], [ ApiConnector.count, ApiOperation.count, ModuleDefinition.count ]
  end

  test "a Config Item the project does not have is refused and nothing is created" do
    create_service(payload(connector: { name: "billing", baseUrl: "https://api.example.com", authType: "bearer",
                                        authConfig: { config_item_name: "NOT_THERE" } }))

    assert_response :unprocessable_content
    assert json["errors"].key?("connector.auth_config")
    assert_equal 0, ApiConnector.count
    assert_equal 0, ConfigItem.count
  end

  test "an existing Config Item is accepted" do
    create(:config_item, scope: @project, name: "BILLING_TOKEN", item_type: :secret, value: "tok")

    create_service(payload(connector: { name: "billing", baseUrl: "https://api.example.com", authType: "bearer",
                                        authConfig: { config_item_name: "BILLING_TOKEN" } },
                           confirmedSecretHost: [ "BILLING_TOKEN → api.example.com" ]))

    assert_response :created
    assert_equal({ "config_item_name" => "BILLING_TOKEN" }, ApiConnector.sole.auth_config)
  end

  test "an existing Config Item without the host confirmation is a 422" do
    create(:config_item, scope: @project, name: "BILLING_TOKEN", item_type: :secret, value: "tok")

    create_service(payload(connector: { name: "billing", baseUrl: "https://api.example.com", authType: "bearer",
                                        authConfig: { config_item_name: "BILLING_TOKEN" } }))

    assert_response :unprocessable_content
    assert json["errors"].key?("connector.confirmed_secret_host")
    assert_equal 0, ApiConnector.count
  end

  test "a request cannot choose its own review state, origin or project" do
    other = create(:project, company: @company, owner: @user)
    body = payload
    body[:connector].merge!(origin: "mcp", reviewedAt: nil, scopeId: other.id, createdById: 0)

    create_service(body)

    assert_response :created
    connector = ApiConnector.sole
    assert_equal [ "web", @project.id, @user.id ], [ connector.origin, connector.scope_id, connector.created_by_id ]
  end

  test "more than 200 operations is a clear 422" do
    body = payload(operations: Array.new(201) { |i| { name: "op_#{i}", httpMethod: "GET", path: "/o#{i}", effect: "read" } })

    create_service(body)

    assert_response :unprocessable_content
    assert_match(/at most 200/, json["error"])
  end

  test "a missing connector or no operations is a 422" do
    create_service(operations: [])
    assert_response :unprocessable_content

    create_service(connector: "x", operations: [ { name: "a" } ])
    assert_response :unprocessable_content
  end

  test "a plain http base URL is refused by the connector's own validation" do
    create_service(payload(connector: { name: "billing", baseUrl: "http://api.example.com", authType: "none" }))

    assert_response :unprocessable_content
    assert json["errors"]["connector"].any?
  end

  test "the feature flag gates it" do
    post company_project_api_service_setups_path(@project), params: payload, as: :json

    assert_response :not_found
    assert_equal 0, ApiConnector.count
  end

  test "is limited to 20 a minute per user" do
    limits = ActiveSupport::Cache::MemoryStore.new
    store = Web::Company::Projects::ApiServiceSetupsController.cache_store

    store.stub(:increment, ->(*args, **options) { limits.increment(*args, **options) }) do
      enabled do
        20.times { |i| post company_project_api_service_setups_path(@project), params: payload(connector: { name: "c#{i}", baseUrl: "https://api.example.com" }), as: :json }
        post company_project_api_service_setups_path(@project), params: payload, as: :json
      end
    end

    assert_response :too_many_requests
  end
end

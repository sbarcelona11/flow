# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ApiConnectorImportsControllerTest < ActionDispatch::IntegrationTest
  CURL = "curl -X POST https://api.example.com/v1/things -H 'Content-Type: application/json' -d '{\"a\":1}'"

  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    @connector = create(:api_connector, scope: @project)
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  def draft(name, **overrides)
    { name: name, http_method: "GET", path: "/#{name}", summary: nil, description: nil, effect: "read",
      input_schema: { type: "object", properties: {} } }.merge(overrides)
  end

  test "import preview returns drafts and warnings without saving" do
    enabled { post preview_company_project_api_connector_imports_path(@project), params: { source: "curl", value: CURL }, as: :json }

    assert_response :success
    body = response.parsed_body
    assert_equal "https://api.example.com", body["base_url"]
    assert_equal "POST", body["drafts"].first["http_method"]
    assert_kind_of Array, body["warnings"]
    assert_equal 0, ApiOperation.count
  end

  test "import preview also returns servers and auth suggestions, and no credential value" do
    token = "sk-live-9f8e7d6c5b4a"
    enabled do
      post preview_company_project_api_connector_imports_path(@project),
           params: { source: "curl", value: "curl https://api.example.com/v1/things -H 'Authorization: Bearer #{token}'" }, as: :json
    end

    assert_response :success
    body = response.parsed_body
    assert_equal [ "https://api.example.com" ], body["servers"]
    assert_equal [ { "auth_type" => "bearer", "header_name" => nil, "query_param" => nil } ], body["auth_suggestions"]
    assert_not_includes response.body, token
    assert_includes body["drafts"].first.keys, "tag"
    assert_includes body["drafts"].first.keys, "response_hint"
  end

  test "a regexp timeout while reading a source is a 422, never a 500" do
    Rest::OpenapiImporter.stubs(:from_text).raises(Regexp::TimeoutError)

    enabled { post preview_company_project_api_connector_imports_path(@project), params: { source: "openapi_text", value: "x" }, as: :json }

    assert_response :unprocessable_content
  end

  test "import preview reports an unreadable source as 422" do
    enabled { post preview_company_project_api_connector_imports_path(@project), params: { source: "openapi_text", value: "not: [an openapi" }, as: :json }

    assert_response :unprocessable_content
    assert response.parsed_body["error"].present?
  end

  test "import preview rejects an unknown source" do
    enabled { post preview_company_project_api_connector_imports_path(@project), params: { source: "ftp", value: "x" }, as: :json }

    assert_response :unprocessable_content
  end

  test "import create saves the chosen drafts in one transaction" do
    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector),
           params: { drafts: [ draft("list_things"), draft("make_thing", http_method: "POST", effect: "write") ] }, as: :json
    end

    assert_redirected_to edit_company_project_api_connector_path(@project, @connector)
    assert_equal %w[list_things make_thing], @connector.api_operations.order(:name).pluck(:name)
  end

  test "import create keeps schema property names as written" do
    schema = { type: "object", properties: { query: { type: "object", properties: { pageSize: { type: "integer" } } } } }

    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector),
           params: { drafts: [ draft("list_things", input_schema: schema) ] }, as: :json
    end

    assert_equal [ "pageSize" ], @connector.api_operations.first.input_schema.dig("properties", "query", "properties").keys
  end

  test "import create still accepts the method under its old name" do
    legacy = draft("make_thing", effect: "write").except(:http_method).merge(method: "POST")

    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector), params: { drafts: [ legacy ] }, as: :json
    end

    assert_equal "POST", @connector.api_operations.find_by!(name: "make_thing").http_method
  end

  test "import create saves nothing if one draft is invalid" do
    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector),
           params: { drafts: [ draft("list_things"), draft("make_thing", http_method: "POST", effect: "read") ] }, as: :json
    end

    assert_response :unprocessable_content
    assert_equal [ "1" ], response.parsed_body["errors"].keys
    assert_equal 0, @connector.api_operations.count
  end

  test "import create saves nothing if two drafts share a name" do
    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector),
           params: { drafts: [ draft("same"), draft("same", path: "/other") ] }, as: :json
    end

    assert_response :unprocessable_content
    assert_equal 0, @connector.api_operations.count
  end

  test "404 when the flag is off" do
    post preview_company_project_api_connector_imports_path(@project), params: { source: "curl", value: CURL }, as: :json
    assert_response :not_found
  end

  test "a viewer cannot import" do
    viewer = create(:user, :onboarding_completed, company: @company, membership_role: :viewer, password: AuthHelper::TEST_PASSWORD)
    @project.add_collaborator(viewer)
    sign_in_as(viewer)

    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector), params: { drafts: [ draft("x_op") ] }, as: :json
    end

    assert_equal 0, @connector.api_operations.count
  end

  test "a viewer cannot preview an import" do
    viewer = create(:user, :onboarding_completed, company: @company, membership_role: :viewer, password: AuthHelper::TEST_PASSWORD)
    @project.add_collaborator(viewer)
    sign_in_as(viewer)

    enabled { post preview_company_project_api_connector_imports_path(@project), params: { source: "curl", value: CURL }, as: :json }

    assert_not response.successful?
    assert_no_match(/api\.example\.com/, response.body)
  end

  test "import preview is limited to 20 a minute per user" do
    limits = ActiveSupport::Cache::MemoryStore.new
    store = Web::Company::Projects::ApiConnectorImportsController.cache_store
    preview = -> { post preview_company_project_api_connector_imports_path(@project), params: { source: "curl", value: CURL }, as: :json }

    store.stub(:increment, ->(*args, **options) { limits.increment(*args, **options) }) do
      enabled do
        20.times do
          preview.call
          assert_response :success
        end
        preview.call
      end
    end

    assert_response :too_many_requests
    assert_match(/Too many imports/, response.parsed_body["error"])
  end

  test "import create stamps every operation as reviewed by the signed-in person" do
    enabled do
      post company_project_api_connector_api_connector_imports_path(@project, @connector),
           params: { drafts: [ draft("list_things"), draft("make_thing", http_method: "POST", effect: "write") ] }, as: :json
    end

    operations = @connector.api_operations.to_a
    assert_equal 2, operations.size
    operations.each do |operation|
      assert_equal "web", operation.origin
      assert_equal @user, operation.created_by
      assert_equal @user, operation.reviewed_by
      assert_not_nil operation.reviewed_at
    end
  end
end

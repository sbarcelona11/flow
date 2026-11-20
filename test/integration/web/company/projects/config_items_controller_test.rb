# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ConfigItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    sign_in_as(@user)
  end

  test "index renders config page" do
    get company_project_config_items_path(@project)
    assert_inertia_page "Projects/Config/ConfigPage"
  end

  test "create redirects on success" do
    post company_project_config_items_path(@project), params: {
      config_item: { name: "API_KEY", value: "secret", item_type: "variable" }
    }
    assert_response :redirect
  end

  test "create answers JSON with the created name and never the value" do
    post company_project_config_items_path(@project), params: {
      config_item: { name: "API_KEY", value: "s3cret-value", item_type: "secret" }
    }, as: :json

    assert_response :created
    assert_equal({ "name" => "API_KEY" }, response.parsed_body)
    assert_not_includes response.body, "s3cret-value"
    assert_equal "s3cret-value", ConfigItem.find_by!(name: "API_KEY").decrypted_value
  end

  test "create answers a duplicate name with a 422 and the errors" do
    create(:config_item, scope: @project, name: "API_KEY")

    post company_project_config_items_path(@project), params: {
      config_item: { name: "API_KEY", value: "x", item_type: "variable" }
    }, as: :json

    assert_response :unprocessable_content
    assert response.parsed_body["errors"]["name"].present?
    assert response.parsed_body["error"].present?
    assert_equal 1, ConfigItem.where(name: "API_KEY").count
  end

  test "an HTML create that fails still redirects back" do
    create(:config_item, scope: @project, name: "API_KEY")

    post company_project_config_items_path(@project), params: { config_item: { name: "API_KEY", value: "x", item_type: "variable" } }

    assert_redirected_to company_project_config_items_path(@project)
  end

  test "update redirects on success" do
    item = create(:config_item, scope: @project)

    patch company_project_config_item_path(@project, item), params: {
      config_item: { value: "updated" }
    }
    assert_response :redirect
  end

  test "destroy redirects" do
    item = create(:config_item, scope: @project)

    delete company_project_config_item_path(@project, item)
    assert_response :redirect
  end
end

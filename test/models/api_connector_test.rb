# frozen_string_literal: true

require "test_helper"

class ApiConnectorTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
  end

  def build_connector(**attrs)
    build(:api_connector, scope: @project, **attrs)
  end

  test "a valid connector saves with tenant columns filled" do
    connector = build_connector
    assert connector.save, connector.errors.full_messages.to_sentence
    assert_equal @project.id, connector.project_id
    assert_equal @project.company_id, connector.company_id
    assert_equal "api.example.com", connector.host
  end

  test "refuses an http base URL" do
    connector = build_connector(base_url: "http://api.example.com")

    assert_not connector.valid?
    assert_includes connector.errors[:base_url], "must use https"
  end

  test "refuses a private address" do
    connector = build_connector(base_url: "https://10.0.0.5/v1")

    assert_not connector.valid?
    assert_includes connector.errors[:base_url], "cannot point to private or internal network addresses"
  end

  test "refuses a literal Authorization default header" do
    connector = build_connector(default_headers: { "Authorization" => "Bearer abc" })

    assert_not connector.valid?
    assert_match(/Authorization looks like a credential/, connector.errors[:default_headers].first)
  end

  test "refuses key, token and secret header names but allows plain ones" do
    %w[X-Api-Key X-Auth-Token Client-Secret Cookie].each do |header|
      assert_not build_connector(default_headers: { header => "v" }).valid?, "#{header} accepted"
    end
    assert build_connector(default_headers: { "Accept" => "application/json", "X-Tenant" => "acme" }).valid?
  end

  test "bearer auth needs a config item name" do
    connector = build_connector(auth_type: "bearer", auth_config: {})
    assert_not connector.valid?
    assert_match(/config_item_name is required/, connector.errors[:auth_config].first)

    connector.auth_config = { "config_item_name" => "not a name" }
    assert_not connector.valid?

    connector.auth_config = { "config_item_name" => "STRIPE_KEY" }
    assert connector.valid?, connector.errors.full_messages.to_sentence
  end

  test "api key auth needs its header name or query parameter" do
    assert_not build_connector(auth_type: "api_key_header", auth_config: { "config_item_name" => "K" }).valid?
    assert build_connector(auth_type: "api_key_header",
                           auth_config: { "config_item_name" => "K", "header_name" => "X-Api-Key" }).valid?
    assert_not build_connector(auth_type: "api_key_query", auth_config: { "config_item_name" => "K" }).valid?
    assert build_connector(auth_type: "api_key_query",
                           auth_config: { "config_item_name" => "K", "query_param" => "api_key" }).valid?
  end

  test "basic auth needs a username and a password item" do
    assert_not build_connector(auth_type: "basic", auth_config: { "username_item" => "U" }).valid?
    assert build_connector(auth_type: "basic",
                           auth_config: { "username_item" => "API_USER", "password_item" => "API_PASS" }).valid?
  end

  test "an unknown auth type is refused" do
    assert_not build_connector(auth_type: "oauth").valid?
  end

  test "names are unique per project among live connectors" do
    create(:api_connector, scope: @project, name: "billing")

    assert_not build_connector(name: "billing").valid?
    assert build_connector(name: "billing", scope: create(:project, :standalone)).valid?
  end

  test "archiving keeps operations but hides the connector" do
    connector = create(:api_connector, scope: @project)
    operation = create(:api_operation, api_connector: connector)

    connector.archive!

    assert connector.archived?
    assert_not_includes ApiConnector.for_project(@project), connector
    assert ApiOperation.exists?(operation.id)
    assert build_connector(name: connector.name).valid?
  end

  test "only a project can scope a connector" do
    connector = build(:api_connector, scope: @project.company)

    assert_not connector.valid?
    assert_includes connector.errors[:scope_type], "must be a project"
  end

  test "refuses userinfo, a query, a fragment and a blank host in the base URL" do
    [ "https://u:p@api.example.com", "https://api.example.com/?x=1", "https://api.example.com/#a",
      "https:///v1" ].each do |url|
      assert_not build_connector(base_url: url).valid?, "#{url} accepted"
    end
  end

  test "keeps a base path and strips the trailing slash" do
    connector = build_connector(base_url: "https://api.example.com/v1/")

    assert connector.save, connector.errors.full_messages.to_sentence
    assert_equal "https://api.example.com/v1", connector.reload.base_url
  end

  test "archiving does not re-check the base URL" do
    connector = create(:api_connector, scope: @project)
    connector.update_columns(base_url: "https://10.0.0.5/v1")

    connector.archive!

    assert connector.reload.archived?
  end
end

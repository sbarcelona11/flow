# frozen_string_literal: true

require "test_helper"

# Policy (Web::Company::Projects::ApiServiceSetupsPolicy, ApiOperationsPolicy#test_call?): both are project writes.
class Web::Company::Projects::ApiServiceSetupsAuthorizationTest < ActionDispatch::IntegrationTest
  include AuthorizationMatrix

  setup do
    setup_project_authz_personas
    resolve_hosts_publicly!
  end

  teardown { teardown_authz }

  def flagged(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  test "creating a service is a project write" do
    flagged do
      assert_project_write(allowed: :created) do |role|
        post company_project_api_service_setups_path(@project), params: {
          connector: { name: "svc-#{role}", baseUrl: "https://api.example.com" },
          operations: [ { name: "list_things", httpMethod: "GET", path: "/things", effect: "read" } ]
        }, as: :json
      end
    end
    assert_equal 3, ApiConnector.where(scope: @project).where("name LIKE 'svc-%'").count, "only owner, admin and collaborator may create"
  end

  test "trying an operation is a project write" do
    connector = create(:api_connector, scope: @project)
    operation = create(:api_operation, api_connector: connector, name: "list_things")
    stub_request(:get, "https://api.example.com/v1/things").to_return(status: 200, body: "[]", headers: { "Content-Type" => "application/json" })

    flagged do
      assert_project_write(allowed: :success) do
        post test_call_company_project_api_connector_api_operation_path(@project, connector, operation), params: { arguments: {} }, as: :json
      end
    end
    assert_equal 3, Audit.where(action: "rest.test_call").count
  end
end

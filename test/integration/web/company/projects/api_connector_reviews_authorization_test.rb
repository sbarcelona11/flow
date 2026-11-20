# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ApiConnectorReviewsAuthorizationTest < ActionDispatch::IntegrationTest
  include AuthorizationMatrix

  setup { setup_project_authz_personas }

  teardown { teardown_authz }

  def flagged(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  test "reading a review is a project read" do
    connector = create(:api_connector, :proposed, scope: @project, name: "to-review")

    flagged { assert_project_read { get review_company_project_api_connector_path(@project, connector), as: :json } }
  end

  test "approving is a project write and a viewer cannot approve" do
    flagged do
      assert_project_write(allowed: :success) do |role|
        waiting = create(:api_connector, :proposed, scope: @project, name: "a-#{role.to_s.dasherize}")
        post approve_company_project_api_connector_path(@project, waiting),
             params: { expected_digest: Authoring::Review.digest_for(waiting) }, as: :json
        assert_not ApiConnector.find(waiting.id).reviewed? if role == :viewer
      end
    end
  end

  test "rejecting is a project write and a viewer cannot reject" do
    flagged do
      assert_project_write(allowed: :success) do |role|
        waiting = create(:api_connector, :proposed, scope: @project, name: "r-#{role.to_s.dasherize}")
        post reject_company_project_api_connector_path(@project, waiting), as: :json
        assert_not ApiConnector.find(waiting.id).rejected? if role == :viewer
      end
    end
  end
end

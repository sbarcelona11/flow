# frozen_string_literal: true

require "test_helper"

# Policy (Api::V1::Projects::ActionTargetsPolicy): index => project_accessible?.
class Api::V1::Projects::ActionTargetsAuthorizationTest < ActionDispatch::IntegrationTest
  include AuthorizationMatrix

  setup { setup_project_authz_personas }

  teardown { teardown_authz }

  test "index is a project read" do
    with_feature(:workflow_action_steps, true, company: @company) do
      assert_project_read(transport: :api) { get api_v1_project_action_targets_path(@project), as: :json }
    end
  end
end

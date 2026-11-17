# frozen_string_literal: true

require "test_helper"

# Request-level authorization matrix for the project-scoped Automations list,
# via the shared AuthorizationMatrix harness (docs/testing.md §2). It follows the
# Workflows index: a project read (Web::Company::Projects::AutomationsPolicy),
# behind the automations_canvas flag, enabled here for the project's company.
class Web::Company::Projects::AutomationsAuthorizationTest < ActionDispatch::IntegrationTest
  include AuthorizationMatrix

  setup do
    setup_project_authz_personas
    create(:workflow, scope: @project)
  end

  teardown { teardown_authz }

  test "index is a project read" do
    with_feature(:automations_canvas, true, company: @company) do
      assert_project_read { get company_project_automations_path(@project) }
    end
  end
end

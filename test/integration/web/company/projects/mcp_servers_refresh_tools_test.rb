# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::MCPServersRefreshToolsTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @owner = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @owner)
    @server = create(:mcp_server, scope: @project, kind: :custom, transport: :http, url: "https://mcp.example.com/mcp")
    @tools = [ { "name" => "search", "description" => "Search", "description_digest" => "d", "schema_digest" => "s",
                 "input_schema" => { "type" => "object" }, "output_schema" => nil, "annotations" => {} } ]
  end

  def probe_ok = MCP::ToolListProbe::Result.new(status: :ok, tools: @tools)

  test "refresh_tools captures a baseline when the server has none" do
    sign_in_as(@owner)
    MCP::ToolListProbe.stubs(:call).returns(probe_ok)

    post refresh_tools_company_project_mcp_server_path(@project, @server)

    assert_redirected_to company_project_mcp_servers_path(@project)
    assert_equal "Tools loaded.", flash[:notice]
    assert_equal "Search", @server.reload.tool_snapshot["tools"].sole["description"]
  end

  test "refresh_tools enriches an existing baseline" do
    sign_in_as(@owner)
    @server.update!(tool_snapshot: { "tools" => [ @tools.first.slice("name", "description_digest", "schema_digest") ] },
                    tool_snapshot_at: 1.day.ago)
    MCP::ToolListProbe.stubs(:call).returns(probe_ok)

    post refresh_tools_company_project_mcp_server_path(@project, @server)

    assert_equal "Tools loaded.", flash[:notice]
    assert_equal({ "type" => "object" }, @server.reload.tool_snapshot["tools"].sole["input_schema"])
  end

  test "refresh_tools warns when the tools changed since they were approved" do
    sign_in_as(@owner)
    @server.update!(tool_snapshot: { "tools" => [ @tools.first.merge("schema_digest" => "old") ] }, tool_snapshot_at: 1.day.ago)
    MCP::ToolListProbe.stubs(:call).returns(probe_ok)

    post refresh_tools_company_project_mcp_server_path(@project, @server)

    assert_match(/changed since they were approved/, flash[:alert])
    assert_equal [ "search" ], @server.reload.tool_drift["changed"]
  end

  test "refresh_tools probes an OAuth server with the current user's token" do
    sign_in_as(@owner)
    @server.update!(auth_type: :oauth, credential_scope: :per_user)
    Oauth::TokenService.expects(:access_token_for).with(server: @server, user: @owner).returns("tok_1")
    MCP::ToolListProbe.expects(:call).with(server: @server, access_token: "tok_1").returns(probe_ok)

    post refresh_tools_company_project_mcp_server_path(@project, @server)

    assert_equal "Tools loaded.", flash[:notice]
  end

  test "refresh_tools reports the probe's error" do
    sign_in_as(@owner)
    MCP::ToolListProbe.stubs(:call).returns(MCP::ToolListProbe::Result.new(status: :error, tools: [], error: "boom"))

    post refresh_tools_company_project_mcp_server_path(@project, @server)

    assert_match(/boom/, flash[:alert])
  end

  test "a viewer cannot refresh tools" do
    viewer = create(:user, :onboarding_completed, company: @company, membership_role: :viewer, password: AuthHelper::TEST_PASSWORD)
    @project.add_collaborator(viewer)
    sign_in_as(viewer)
    MCP::ToolListProbe.expects(:call).never

    post refresh_tools_company_project_mcp_server_path(@project, @server)

    assert_redirected_to root_path
    assert_not @server.reload.tool_baseline?
  end
end

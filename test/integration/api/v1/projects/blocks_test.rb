# frozen_string_literal: true

require "test_helper"

class Api::V1::Projects::BlocksTest < ActionDispatch::IntegrationTest
  SCHEMA = { "type" => "object", "properties" => { "query" => { "type" => "string" } } }.freeze

  setup do
    @company = create(:company)
    @owner = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @owner)
    @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", snapshot_tools: [
      { "name" => "search", "description" => "Find", "input_schema" => SCHEMA, "annotations" => { "readOnlyHint" => true } }
    ])
    sign_in_as(@owner)
  end

  def define_block(slug, project: @project, config: nil, **fields)
    manifest = { "kind" => "block", "namespace" => "acme", "slug" => slug, "version" => 1, "label" => slug.titleize,
                 "description" => "Does <b>things</b>", "executor" => "action",
                 "uses" => { "transport" => "mcp", "connection" => "Billing", "operation" => "search" },
                 "ports" => { "in" => {}, "out" => { "hit_list" => "aixle/string@1" } }, "effect" => "write" }
    manifest["config"] = config if config
    create(:module_definition, scope: project, kind: "block", namespace: "acme", slug: slug, manifest: manifest.merge(fields))
  end

  def list
    with_feature(:workflow_action_steps, true, company: @company) { get api_v1_project_blocks_path(@project), as: :json }
    response.parsed_body.index_by { |block| block["key"] }
  end

  test "lists blocks with their status, target and effective effect" do
    define_block("lookup", config: { "type" => "object", "properties" => { "query" => { "type" => "string" } } })
    define_block("broken", config: { "type" => "object", "properties" => { "colour_name" => { "type" => "string" } } })

    blocks = list

    assert_response :success
    lookup = blocks.fetch("acme/lookup@1")
    assert_equal [ "valid", nil, "action", "write", "Does <b>things</b>" ],
                 lookup.values_at("status", "reason", "executor", "effect", "description")
    assert_equal({ "in" => {}, "out" => { "hit_list" => "aixle/string@1" } }, lookup["ports"])
    assert_equal({ "type" => "object", "properties" => { "query" => { "type" => "string" } } }, lookup["config"])
    assert_equal({ "type" => "mcp_tool", "connection" => "Billing", "operation" => "search", "name" => "search",
                   "mcpServerId" => @server.id, "tool" => "search", "toolId" => nil, "apiOperationId" => nil }, lookup["target"])
    broken = blocks.fetch("acme/broken@1")
    assert_equal "invalid", broken["status"]
    assert_equal "config property colour_name is not an argument of search", broken["reason"]
    assert_nil broken["target"]
    assert_nil broken["effect"]
    assert_equal({ "colour_name" => { "type" => "string" } }, broken["config"]["properties"])
  end

  test "another project's blocks are not listed" do
    other = create(:project, company: @company, owner: @owner)
    define_block("theirs", project: other)

    assert_empty list
  end

  test "404 when workflow_action_steps is off" do
    get api_v1_project_blocks_path(@project), as: :json

    assert_response :not_found
  end

  test "lists each block's origin and review state" do
    define_block("lookup")

    blocks = list

    assert_equal [ "web", "reviewed" ], blocks.fetch("acme/lookup@1").values_at("origin", "reviewState")
  end
end

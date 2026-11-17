# frozen_string_literal: true

require "test_helper"

class Actions::CatalogTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
  end

  test "lists MCP tools with schemas and project Wrappers" do
    schema = { "type" => "object", "properties" => { "q" => { "type" => "string" } } }
    server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", transport: :http,
                                 snapshot_tools: [ { "name" => "search", "description" => "Find invoices", "input_schema" => schema,
                                                     "annotations" => { "readOnlyHint" => true } },
                                                   { "name" => "void", "annotations" => { "destructiveHint" => true } } ])
    wrapper = create(:tool, scope: @project, name: "invoice_lines", display_name: "Invoice lines",
                            description: "Computes lines", input_schema: { "type" => "object" })
    create(:tool, :disabled, scope: @project)
    create(:tool, scope: create(:project, :standalone))
    create(:mcp_server, :with_tool_schemas, scope: create(:project, :standalone))

    targets = Actions::Catalog.new(@project).targets

    assert_equal [ [ "mcp_tool", server.id, "Billing", "search", "read" ], [ "mcp_tool", server.id, "Billing", "void", "irreversible" ],
                   [ "wrapper", nil, nil, nil, "write" ] ],
                 targets.map { |t| [ t.type, t.mcp_server_id, t.server_name, t.tool, t.base_effect ] }
    search = targets.first
    assert_equal "search", search.name
    assert_equal "Find invoices", search.description
    assert_equal schema, search.input_schema
    assert_equal false, search.drifted # rubocop:disable Minitest/RefuteFalse
    wrapper_target = targets.last
    assert_equal [ wrapper.id, "Invoice lines", "Computes lines" ], [ wrapper_target.tool_id, wrapper_target.name, wrapper_target.description ]
  end

  test "never lists stdio servers or archived servers" do
    create(:mcp_server, :with_tool_schemas, :stdio_transport, scope: @project, command: "npx @acme/server@1.0.0")
    create(:mcp_server, :with_tool_schemas, scope: @project, archived_at: Time.current)
    create(:mcp_server, :with_tool_schemas, :disabled, scope: @project)
    create(:mcp_server, scope: @project)
    legacy = create(:mcp_server, :with_tool_schemas, scope: @project)
    legacy.update!(tool_snapshot: { "tools" => [ { "name" => "old", "description_digest" => "x", "schema_digest" => "y" } ] })

    assert_empty Actions::Catalog.new(@project).targets
  end

  test "marks drifted tools" do
    server = create(:mcp_server, :with_tool_schemas, scope: @project,
                                 snapshot_tools: [ { "name" => "search" }, { "name" => "send_mail" } ])
    server.update!(tool_drift: { "changed" => [ "send_mail" ] })

    targets = Actions::Catalog.new(@project).targets

    assert_equal({ "search" => false, "send_mail" => true }, targets.to_h { |t| [ t.tool, t.drifted ] })
  end

  test "finds the target a step's kind_config names" do
    server = create(:mcp_server, :with_tool_schemas, scope: @project)
    wrapper = create(:tool, scope: @project)
    catalog = Actions::Catalog.new(@project)

    assert_equal "search", catalog.find({ "target" => "mcp_tool", "mcp_server_id" => server.id, "tool" => "search" }).tool
    assert_equal wrapper.id, catalog.find({ "target" => "wrapper", "tool_id" => wrapper.id }).tool_id
    assert_nil catalog.find({ "target" => "mcp_tool", "mcp_server_id" => server.id, "tool" => "missing" })
    assert_nil catalog.find({ "target" => "wrapper", "tool_id" => create(:tool).id })
  end

  test "lists enabled REST operations of the project" do
    schema = { "type" => "object", "properties" => { "query" => { "type" => "object", "properties" => {} } } }
    payments = create(:api_connector, scope: @project, name: "Payments")
    refund = create(:api_operation, api_connector: payments, name: "refund", method: "DELETE", path: "/charges",
                                    effect: "irreversible", description: "Refund a charge", input_schema: schema)
    create(:api_operation, api_connector: payments, name: "disabled_one", enabled: false)
    create(:api_operation, api_connector: create(:api_connector, scope: @project, enabled: false))
    create(:api_operation, api_connector: create(:api_connector))

    targets = Actions::Catalog.new(@project).targets

    assert_equal [ [ "rest_operation", refund.id, "Payments", "refund", "Refund a charge", schema, "irreversible", false ] ],
                 targets.map { |t| [ t.type, t.api_operation_id, t.server_name, t.name, t.description, t.input_schema, t.base_effect, t.drifted ] }
    assert_equal refund.id, Actions::Catalog.new(@project).find({ "target" => "rest_operation", "api_operation_id" => refund.id }).api_operation_id
  end

  test "an archived connector's operations are not targets" do
    connector = create(:api_connector, scope: @project)
    operation = create(:api_operation, api_connector: connector)
    connector.update!(archived_at: Time.current)
    catalog = Actions::Catalog.new(@project)

    assert_empty catalog.targets
    assert_nil catalog.find({ "target" => "rest_operation", "api_operation_id" => operation.id })
  end
end

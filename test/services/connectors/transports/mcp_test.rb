# frozen_string_literal: true

require "test_helper"

class Connectors::Transports::MCPTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
    @schema = { "type" => "object", "properties" => { "q" => { "type" => "string" } } }
    @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", transport: :http,
                                                      snapshot_tools: [ { "name" => "search", "description" => "Find invoices",
                                                                          "input_schema" => @schema,
                                                                          "annotations" => { "readOnlyHint" => true } },
                                                                        { "name" => "void", "annotations" => { "destructiveHint" => true } } ])
    @transport = Connectors::Registry.fetch(:mcp).new
  end

  test "is registered for the mcp_tool target" do
    assert_equal Connectors::Transports::MCP, Connectors::Registry.fetch(:mcp)
    assert_equal Connectors::Transports::MCP, Connectors::Registry.for_target("mcp_tool")
    assert_not @transport.async?
  end

  test "operations equal what the catalog built for each tool" do
    expected = [ Connectors::Operation.new(key: "search", name: "search", description: "Find invoices", input_schema: @schema,
                                           output_schema: nil, base_effect: "read", drifted: false),
                 Connectors::Operation.new(key: "void", name: "void", description: "void tool", input_schema: { "type" => "object" },
                                           output_schema: nil,
                                           base_effect: "irreversible", drifted: false) ]

    assert_equal expected, @transport.operations(@server)
  end

  test "flags drifted tools" do
    @server.update!(tool_drift: { "changed" => [ "void" ] })

    assert_equal({ "search" => false, "void" => true }, @transport.operations(@server).to_h { |o| [ o.key, o.drifted ] })
  end

  test "lists servers the way the catalog did and looks one up by id" do
    create(:mcp_server, :with_tool_schemas, :stdio_transport, scope: @project, command: "npx @acme/server@1.0.0")
    create(:mcp_server, :with_tool_schemas, scope: create(:project, :standalone))

    assert_equal [ @server ], @transport.connections(@project).to_a
    assert_equal @server, @transport.connection_for({ "mcp_server_id" => @server.id }, @project)
    assert_nil @transport.connection_for({ "mcp_server_id" => 0 }, @project)
  end

  def gone
    Connectors::Operation.new(key: "gone", name: "gone", description: nil, input_schema: nil, output_schema: nil,
                              base_effect: nil, drifted: false)
  end

  test "labels match the action call labels" do
    operation = @transport.operations(@server).first

    assert_equal "Billing", @transport.owner(@server)
    assert_equal "Billing · search", @transport.label(@server, operation)
    assert_equal "search", @transport.target_name(@server, operation)
    assert_equal "the server · gone", @transport.label(nil, gone)
  end

  test "call delegates to the tool caller and returns a port result" do
    context = Connectors::Context.new(project: @project, user: nil, step_run_id: 1, run_id: 2)
    caller_result = MCP::ToolCaller::Result.new(ok: true, structured: { "id" => 7 }, text: "created", unknown: false,
                                                config_item_names: [ "K" ])
    MCP::ToolCaller.expects(:call).with(server: @server, tool: "search", arguments: { "q" => "x" }, user: nil).returns(caller_result)

    result = @transport.call(connection: @server, operation: @transport.operations(@server).first,
                             arguments: { "q" => "x" }, context: context)

    assert_kind_of Connectors::Result, result
    assert_equal [ true, { "id" => 7 }, "created", [ "K" ] ], [ result.ok?, result.structured, result.text, result.config_item_names ]
  end
end

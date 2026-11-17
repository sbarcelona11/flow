# frozen_string_literal: true

require "test_helper"

class Connectors::AsyncPortTest < ActiveSupport::TestCase
  test "a transport is synchronous unless it says otherwise" do
    transport = Class.new(Connectors::Transport).new

    assert_not transport.async?
    assert_raises(RuntimeError) { transport.status({}) }
  end

  test "an asynchronous transport without status or finish raises NotImplementedError" do
    transport = Class.new(Connectors::Transport) { def async? = true }.new

    assert_raises(NotImplementedError) { transport.status({}) }
    assert_raises(NotImplementedError) { transport.finish({}) }
  end

  test "the catalog lists MCP, then Wrapper, then REST targets" do
    project = create(:project, :standalone)
    create(:mcp_server, :with_tool_schemas, scope: project, snapshot_tools: [ { "name" => "search" } ])
    create(:tool, scope: project)
    create(:api_operation, api_connector: create(:api_connector, scope: project))

    assert_equal %w[mcp_tool wrapper rest_operation], Actions::Catalog.new(project).targets.map(&:type)
  end
end

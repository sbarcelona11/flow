# frozen_string_literal: true

require "test_helper"

module Actions
  class BlockOutputNameTest < ActiveSupport::TestCase
    setup do
      @company = create(:company)
      @project = create(:project, company: @company, owner: create(:user, company: @company))
      @workflow = create(:workflow, scope: @project)
      @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", snapshot_tools: [
        { "name" => "search", "annotations" => { "readOnlyHint" => true } }
      ])
      manifest = { "kind" => "block", "namespace" => "acme", "slug" => "lookup", "version" => 1, "label" => "lookup",
                   "executor" => "action", "ports" => { "in" => {}, "out" => { "hits" => "aixle/string@1" } },
                   "uses" => { "transport" => "mcp", "connection" => "Billing", "operation" => "search" } }
      create(:module_definition, scope: @project, kind: "block", namespace: "acme", slug: "lookup", manifest: manifest)
    end

    def problems(**overrides)
      config = { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                 "arguments" => {}, "block" => "acme/lookup@1" }.merge(overrides)
      with_feature(:workflow_action_steps, true, company: @company) do
        build(:step, workflow: @workflow, kind: "action", agent: nil, kind_config: config).tap(&:valid?).errors[:base]
      end
    end

    test "a block step's output is named after the block's first out port" do
      assert_empty problems("output_name" => "hits.json")
      assert_empty problems
    end

    test "any other name chosen for a block step is refused" do
      assert_equal [ "The output name must be hits.json for block acme/lookup@1." ], problems("output_name" => "found.json")
    end
  end
end

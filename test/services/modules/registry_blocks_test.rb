# frozen_string_literal: true

require "test_helper"

module Modules
  class RegistryBlocksTest < ActiveSupport::TestCase
    SEARCH_SCHEMA = { "type" => "object", "properties" => { "query" => { "type" => "string" }, "limit" => { "type" => "integer" } } }.freeze

    setup do
      @project = create(:project, :standalone)
      @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", snapshot_tools: [
        { "name" => "search", "input_schema" => SEARCH_SCHEMA, "annotations" => { "readOnlyHint" => true } }
      ])
    end

    def define_block(slug, config: nil, effect: nil, ports: { "in" => {}, "out" => {} })
      manifest = { "kind" => "block", "namespace" => "acme", "slug" => slug, "version" => 1, "label" => slug, "executor" => "action",
                   "uses" => { "transport" => "mcp", "connection" => "Billing", "operation" => "search" }, "ports" => ports }
      manifest["config"] = config if config
      manifest["effect"] = effect if effect
      create(:module_definition, scope: @project, kind: "block", namespace: "acme", slug: slug, manifest: manifest)
    end

    def entry(slug) = Registry.new(@project).block("acme/#{slug}@1")

    test "a config limited to the operation's arguments resolves to a target and an effective effect" do
      define_block("lookup", config: { "type" => "object", "properties" => { "query" => { "type" => "string" } } }, effect: "write")

      found = entry("lookup")

      assert_equal "valid", found.status, found.reason
      assert_equal [ "mcp_tool", @server.id, "search" ], [ found.target.type, found.target.mcp_server_id, found.target.tool ]
      assert_equal "write", found.effect
    end

    test "the effective effect is the operation's own when the block declares none" do
      define_block("lookup")

      assert_equal "read", entry("lookup").effect
    end

    test "a config property the operation does not take makes the block invalid" do
      define_block("lookup", config: { "type" => "object", "properties" => { "colour" => { "type" => "string" } } })

      found = entry("lookup")

      assert_equal "invalid", found.status
      assert_equal "config property colour is not an argument of search", found.reason
      assert_nil found.target
    end

    test "an x-type in the config that no project type answers to makes the block invalid" do
      define_block("lookup", config: { "type" => "object", "properties" => { "query" => { "type" => "string", "x-type" => "acme/missing@1" } } })

      found = entry("lookup")

      assert_equal "invalid", found.status
      assert_includes found.reason, "acme/missing@1"
    end

    test "a known x-type in the config is accepted" do
      define_block("lookup", config: { "type" => "object", "properties" => { "query" => { "type" => "string", "x-type" => "aixle/string@1" } } })

      assert_equal "valid", entry("lookup").status
    end

    test "a capability block stays unresolved with no target" do
      create(:module_definition, :capability, scope: @project, namespace: "acme", slug: "invoice")
      create(:module_definition, scope: @project, kind: "block", namespace: "acme", slug: "bill",
                                 manifest: { "kind" => "block", "namespace" => "acme", "slug" => "bill", "version" => 1, "label" => "Bill",
                                             "executor" => "action", "uses" => { "capability" => "acme/invoice@1" },
                                             "ports" => { "in" => {}, "out" => {} } })

      found = entry("bill")

      assert_equal "unresolved", found.status
      assert_nil found.target
      assert_nil found.effect
    end
  end
end

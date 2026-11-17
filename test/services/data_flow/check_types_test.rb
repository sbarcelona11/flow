# frozen_string_literal: true

require "test_helper"

class DataFlow::CheckTypesTest < ActiveSupport::TestCase
  USE_SCHEMA = { "type" => "object", "properties" => { "doc" => { "type" => "string" }, "free" => { "type" => "string" } } }.freeze

  setup do
    @company = create(:company)
    @project = create(:project, company: @company, owner: create(:user, company: @company))
    @workflow = create(:workflow, scope: @project)
    @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", snapshot_tools: [
      { "name" => "make", "annotations" => { "readOnlyHint" => true } },
      { "name" => "use", "input_schema" => USE_SCHEMA, "annotations" => { "readOnlyHint" => true } }
    ])
    %w[invoice receipt].each { |slug| define("type", slug, "schema" => { "type" => "string" }) }
    define_block("use", operation: "use", ports: { "in" => {}, "out" => { "done" => "aixle/string@1" } },
                        config: { "type" => "object", "properties" => { "doc" => { "type" => "string", "x-type" => "acme/invoice@1" },
                                                                         "free" => { "type" => "string" } } })
  end

  def define(kind, slug, **fields)
    manifest = { "kind" => kind, "namespace" => "acme", "slug" => slug, "version" => 1, "label" => slug }.merge(fields)
    create(:module_definition, scope: @project, kind: kind, namespace: "acme", slug: slug, manifest: manifest)
  end

  def define_block(slug, operation:, ports:, config: nil)
    define("block", slug, "executor" => "action", "uses" => { "transport" => "mcp", "connection" => "Billing", "operation" => operation },
                          "ports" => ports, **{ "config" => config }.compact)
  end

  def produce(type)
    define_block("make", operation: "make", ports: { "in" => {}, "out" => { "doc" => type } })
  end

  def action(name, block, arguments = {}, tool: "use", depends_on: [])
    with_feature(:workflow_action_steps, true, company: @company) do
      create(:step, workflow: @workflow, name: name, kind: "action", agent: nil, depends_on_step_ids: depends_on,
                    kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => tool, "effect" => "read",
                                   "arguments" => arguments, "block" => block })
    end
  end

  def mismatches
    DataFlow::Check.for_workflow(@workflow.reload, project: @project).issues.select { |issue| issue.code == "type_mismatch" }
  end

  def wire(argument_value, argument: "doc")
    producer = action("Make", "acme/make@1", {}, tool: "make")
    action("Use", "acme/use@1", { argument => argument_value.call(producer) }, depends_on: [ producer.id ])
  end

  test "the same type on both sides is fine" do
    produce("acme/invoice@1")
    wire(->(step) { "{{output:#{step.id}:doc.json}}" })

    assert_empty mismatches
  end

  test "different types are an error naming both" do
    produce("acme/receipt@1")
    consumer = wire(->(step) { "{{output:#{step.id}:doc.json}}" })

    issue = mismatches.sole

    assert_equal "error", issue.severity
    assert_equal consumer.id.to_s, issue.step_key
    assert_equal "arguments.doc", issue.field
    assert_includes issue.message, "acme/invoice@1"
    assert_includes issue.message, "acme/receipt@1"
    assert_nil issue.fix
  end

  test "an untyped side is not checked" do
    produce("acme/receipt@1")
    wire(->(step) { "{{output:#{step.id}:doc.json}}" }, argument: "free")

    assert_empty mismatches
  end

  test "a list into one item asks for a For each" do
    produce("list<acme/invoice@1>")
    wire(->(step) { "{{output:#{step.id}:doc.json}}" })

    issue = mismatches.sole

    assert_includes issue.message, "needs a For each (not available yet)"
    assert_nil issue.fix
  end

  test "a token that is not the whole value is ignored" do
    produce("acme/receipt@1")
    wire(->(step) { "see {{output:#{step.id}:doc.json}}" })

    assert_empty mismatches
  end

  test "an upstream step without a block is not checked" do
    plain = create(:step, workflow: @workflow, name: "Plain")
    action("Use", "acme/use@1", { "doc" => "{{output:#{plain.id}:doc.json}}" }, depends_on: [ plain.id ])

    assert_empty mismatches
  end

  test "the builder's unsaved payload is checked the same way" do
    produce("acme/receipt@1")
    producer = action("Make", "acme/make@1", {}, tool: "make")
    payload = { "steps" => [
      { "key" => producer.id.to_s, "name" => "Make", "kind" => "action", "kind_config" => { "block" => "acme/make@1", "arguments" => {} } },
      { "key" => "new-1", "name" => "Use", "kind" => "action", "depends_on_step_ids" => [ producer.id ],
        "kind_config" => { "block" => "acme/use@1", "arguments" => { "doc" => "{{output:#{producer.id}:doc.json}}" } } }
    ] }

    issues = DataFlow::Check.for_payload(@workflow, payload, project: @project).issues.select { |issue| issue.code == "type_mismatch" }

    assert_equal [ "new-1" ], issues.map(&:step_key)
  end

  test "a workflow without blocks never builds the registry" do
    create(:step, workflow: @workflow, name: "Plain")

    Modules::Registry.stub(:new, ->(*) { flunk "registry built" }) do
      assert_empty mismatches
    end
  end
end

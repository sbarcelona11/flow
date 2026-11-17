# frozen_string_literal: true

require "test_helper"

class DataFlow::CheckActionArgumentsTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @project = create(:project, company: @company, owner: create(:user, company: @company))
    @workflow = create(:workflow, scope: @project)
    @server = create(:mcp_server, :with_tool_schemas, scope: @project, snapshot_tools: [ { "name" => "search", "annotations" => { "readOnlyHint" => true } } ])
    @collect = create(:step, workflow: @workflow, name: "Collect", output_asset_specs: [ { "name" => "summary.md" } ])
  end

  def action(arguments, depends_on: [])
    with_feature(:workflow_action_steps, true, company: @company) do
      create(:step, workflow: @workflow, name: "Use", kind: "action", agent: nil, depends_on_step_ids: depends_on,
                    kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                                   "arguments" => arguments })
    end
  end

  def issues = DataFlow::Check.for_workflow(@workflow.reload, project: @project).issues.select { |i| i.field == "arguments" }

  test "a token for a declared output of an upstream step raises nothing" do
    action({ "q" => "{{output:#{@collect.id}:summary.md}}" }, depends_on: [ @collect.id ])

    assert_empty issues
  end

  test "unknown step, not upstream and undeclared output are errors on the arguments" do
    step = action({ "a" => "{{output:#{@collect.id}:summary.md}}", "b" => "{{output:#{@collect.id}:nope.md}}",
                    "c" => "{{output:999999:x.md}}" })

    by_code = issues.index_by(&:code)

    assert_equal %w[output_not_upstream output_undeclared ref_missing], by_code.keys.sort
    assert_equal [ "error" ], issues.map(&:severity).uniq
    assert_equal [ step.id.to_s ], issues.map(&:step_key).uniq
    assert_equal({ kind: "add_dependency", stepKey: @collect.id.to_s }, by_code["output_not_upstream"].fix)
  end

  test "an upstream step reached through another step counts" do
    middle = create(:step, workflow: @workflow, name: "Middle", depends_on_step_ids: [ @collect.id ])
    action({ "q" => "x {{output:#{@collect.id}:summary.md}}" }, depends_on: [ middle.id ])

    assert_empty issues
  end

  test "the builder's payload is checked with draft keys, an action upstream offering its output name" do
    payload = { "steps" => [
      { "key" => "new-1", "name" => "Fetch", "kind" => "action", "kind_config" => { "output_name" => "found.json", "arguments" => {} } },
      { "key" => "new-2", "name" => "Use", "kind" => "action", "depends_on_step_ids" => [ "new-1" ],
        "kind_config" => { "arguments" => { "a" => "{{output:new-1:found.json}}", "b" => "{{output:new-1:result.json}}" } } }
    ] }

    found = DataFlow::Check.for_payload(@workflow, payload, project: @project).issues.select { |i| i.field == "arguments" }

    assert_equal [ [ "new-2", "output_undeclared" ] ], found.map { |i| [ i.step_key, i.code ] }
  end

  test "type_mismatch is still reported next to the new checks" do
    action({ "q" => "{{output:#{@collect.id}:nope.md}}" })

    assert_includes DataFlow::Check.for_workflow(@workflow.reload, project: @project).issues.map(&:code), "output_undeclared"
  end
end

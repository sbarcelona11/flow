# frozen_string_literal: true

require "test_helper"

module Actions
  class OutputReferencesTest < ActiveSupport::TestCase
    SCHEMA = { "type" => "object", "properties" => { "query" => { "type" => "string" }, "doc" => { "type" => "object" } } }.freeze

    setup do
      @company = create(:company)
      @user = create(:user, company: @company)
      @project = create(:project, company: @company, owner: @user)
      @workflow = create(:workflow, scope: @project)
      @server = create(:mcp_server, :with_tool_schemas, scope: @project, snapshot_tools: [
        { "name" => "search", "input_schema" => SCHEMA, "annotations" => { "readOnlyHint" => true } }
      ])
    end

    def action(name, arguments, depends_on: [], output_name: nil)
      with_feature(:workflow_action_steps, true, company: @company) do
        create(:step, workflow: @workflow, name: name, kind: "action", agent: nil, depends_on_step_ids: depends_on,
                      kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                                     "arguments" => arguments, "output_name" => output_name }.compact)
      end
    end

    def agent_step(name, outputs: [ "summary.md" ], depends_on: [])
      create(:step, workflow: @workflow, name: name, depends_on_step_ids: depends_on,
                    output_asset_specs: outputs.map { |output| { "name" => output } })
    end

    def refusal
      error = assert_raises(ActiveRecord::RecordInvalid) { OutputReferences.verify!(@workflow.reload) }
      error.record.errors[:base].sole
    end

    test "a token for a declared output of a step that runs before is accepted, directly or through another step" do
      first = agent_step("Collect")
      middle = agent_step("Review", depends_on: [ first.id ])
      action("Direct", { "query" => "{{output:#{first.id}:summary.md}}" }, depends_on: [ first.id ])
      action("Transitive", { "query" => "see {{output:#{first.id}:summary.md}}" }, depends_on: [ middle.id ])

      assert_nil OutputReferences.verify!(@workflow.reload)
    end

    test "an action upstream offers its output_name" do
      fetch = action("Fetch", {}, output_name: "found.json")
      action("Use", { "doc" => "{{output:#{fetch.id}:found.json}}" }, depends_on: [ fetch.id ])

      assert_nil OutputReferences.verify!(@workflow.reload)
    end

    test "a step that does not run before the action is refused" do
      other = agent_step("Collect")
      action("Use", { "query" => "{{output:#{other.id}:summary.md}}" })

      assert_equal "\"Use\" reads summary.md from \"Collect\", which does not run before it.", refusal
    end

    test "an output the step does not declare is refused" do
      other = agent_step("Collect")
      action("Use", { "query" => "{{output:#{other.id}:other.md}}" }, depends_on: [ other.id ])

      assert_equal "\"Use\" reads other.md, which \"Collect\" does not declare as an output.", refusal
    end

    test "a step that is gone and a token that cannot be read are refused" do
      gone = agent_step("Gone")
      gone.update_columns(deleted_at: Time.current)
      action("Use", { "query" => "{{output:#{gone.id}:summary.md}}" })
      assert_match(/no longer in this workflow/, refusal)

      Step.where(workflow: @workflow, name: "Use").update_all(
        kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                       "arguments" => { "query" => "{{output:abc:x.md}}" }, "output_name" => "result.json" }
      )
      assert_match(/cannot be read/, refusal)
    end

    test "an action reading its own output is refused" do
      step = action("Loop", {}, output_name: "again.json")
      step.update_columns(kind_config: step.kind_config.merge("arguments" => { "query" => "{{output:#{step.id}:again.json}}" }))

      assert_match(/does not run before it/, refusal)
    end

    test "a workflow without action steps never builds the check" do
      agent_step("Plain")

      DataFlow::Check.stubs(:for_workflow).never

      assert_nil OutputReferences.verify!(@workflow.reload)
    end

    test "every workflow write runs the check" do
      other = agent_step("Collect")
      action("Use", { "query" => "{{output:#{other.id}:summary.md}}" })

      error = assert_raises(ActiveRecord::RecordInvalid) do
        Versions.save!(@workflow, actor: Versions::Actor.ui(@user)) { |workflow| workflow.update!(description: "x") }
      end
      assert_match(/does not run before it/, error.record.errors[:base].sole)
    end

    test "the builder's draft keys are accepted, rewritten to ids, and checked after the rewrite" do
      first = agent_step("Collect")
      payload = lambda do |depends_on|
        { "steps" => [
          { "id" => first.id, "name" => "Collect", "output_asset_specs" => [ { "name" => "summary.md" } ] },
          { "key" => "new-1", "name" => "Fetch", "kind" => "action", "depends_on_step_ids" => [ first.id ],
            "kind_config" => { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                               "arguments" => {}, "output_name" => "found.json" } },
          { "key" => "new-2", "name" => "Use", "kind" => "action", "depends_on_step_ids" => depends_on,
            "kind_config" => { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                               "arguments" => { "query" => "{{output:#{first.id}:summary.md}} {{output:new-1:found.json}}" } } }
        ] }
      end
      save = lambda do |depends_on|
        with_feature(:workflow_action_steps, true, company: @company) do
          Versions.save!(@workflow, actor: Versions::Actor.ui(@user)) { |workflow| WorkflowAggregateSave.new(workflow, payload.call(depends_on)).validate!.apply! }
        end
      end

      assert_raises(ActiveRecord::RecordInvalid) { save.call([ first.id ]) }
      assert_equal 1, @workflow.steps.not_deleted.count

      save.call([ "new-1" ])

      fetch = @workflow.steps.not_deleted.find_by!(name: "Fetch")
      use = @workflow.steps.not_deleted.find_by!(name: "Use")
      assert_equal "{{output:#{first.id}:summary.md}} {{output:#{fetch.id}:found.json}}", use.kind_config.dig("arguments", "query")
    end

    test "arguments that read more outputs than the limit are refused" do
      step = with_feature(:workflow_action_steps, true, company: @company) do
        build(:step, workflow: @workflow, kind: "action", agent: nil,
                     kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                                    "arguments" => { "query" => "{{output:1:a.md}}" * (Step::ACTION_OUTPUT_REFERENCES_MAX + 1) } })
      end

      with_feature(:workflow_action_steps, true, company: @company) { assert_not step.valid? }
      assert_includes step.errors[:kind_config].join, "at most #{Step::ACTION_OUTPUT_REFERENCES_MAX} step outputs"
    end

    test "a step that is valid holds output tokens as placeholders against the tool's schema" do
      first = agent_step("Collect")
      step = with_feature(:workflow_action_steps, true, company: @company) do
        build(:step, workflow: @workflow, kind: "action", agent: nil, depends_on_step_ids: [ first.id ],
                     kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                                    "arguments" => { "doc" => "{{output:#{first.id}:summary.json}}" } })
      end

      with_feature(:workflow_action_steps, true, company: @company) { assert step.valid?, step.errors.full_messages.to_sentence }
    end
  end
end

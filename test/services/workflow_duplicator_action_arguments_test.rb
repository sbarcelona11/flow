# frozen_string_literal: true

require "test_helper"

class WorkflowDuplicatorActionArgumentsTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, company: @company)
    @source_project = create(:project, company: @company, owner: @user)
    @other_project = create(:project, company: @company, owner: @user)
    @server = create(:mcp_server, :with_tool_schemas, scope: @source_project, name: "billing",
                                 snapshot_tools: [ { "name" => "search", "annotations" => { "readOnlyHint" => true } } ])
    @source = create(:workflow, scope: @source_project, name: "Source")
    @collect = create(:step, workflow: @source, name: "Collect", output_asset_specs: [ { "name" => "summary.md" } ])
    with_feature(:workflow_action_steps, true, company: @company) do
      @action = @source.steps.create!(
        name: "Search", position: 50, kind: "action", depends_on_step_ids: [ @collect.id ],
        kind_config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
                       "arguments" => { "q" => "see {{output:#{@collect.id}:summary.md}}", "n" => [ "{{output:#{@collect.id}:summary.md}}" ] } }
      )
    end
  end

  def duplicate(scope)
    with_feature(:workflow_action_steps, true, company: @company) { WorkflowDuplicator.new(@source, target_scope: scope).duplicate! }
  end

  test "output tokens in an action's arguments follow the copied steps in the same and in another project" do
    [ @source_project, @other_project ].each do |scope|
      copy = duplicate(scope)

      collect = copy.steps.not_deleted.find_by!(name: "Collect")
      arguments = copy.steps.not_deleted.find_by!(name: "Search").kind_config["arguments"]
      assert_equal({ "q" => "see {{output:#{collect.id}:summary.md}}", "n" => [ "{{output:#{collect.id}:summary.md}}" ] }, arguments)
    end
  end

  test "a module block is kept inside the project and dropped in another project" do
    manifest = { "kind" => "block", "namespace" => "acme", "slug" => "lookup", "version" => 1, "label" => "lookup",
                 "executor" => "action", "ports" => { "in" => {}, "out" => { "hits" => "aixle/string@1" } },
                 "uses" => { "transport" => "mcp", "connection" => "billing", "operation" => "search" } }
    create(:module_definition, scope: @source_project, kind: "block", namespace: "acme", slug: "lookup", manifest: manifest)
    @action.update_column(:kind_config, @action.kind_config.merge("block" => "acme/lookup@1", "arguments" => {}))

    same = duplicate(@source_project)
    other = duplicate(@other_project)

    assert_equal "acme/lookup@1", same.steps.not_deleted.find_by!(name: "Search").kind_config["block"]
    assert_not other.steps.not_deleted.find_by!(name: "Search").kind_config.key?("block")
  end
end

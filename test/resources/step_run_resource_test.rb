# frozen_string_literal: true

require "test_helper"

class StepRunResourceTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, company: @company)
    @project = create(:project, company: @company, owner: @user)
    @workflow = create(:workflow, scope: @project)
    @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
    @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing",
                                                      snapshot_tools: [ { "name" => "create_invoice" } ])
    config = { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "create_invoice",
               "arguments" => { "customer" => "c_42" }, "effect" => "write" }
    step = with_feature(:workflow_action_steps, true, company: @company) do
      create(:step, workflow: @workflow, kind: "action", kind_config: config)
    end
    @step_run = create(:step_run, workflow_run: @run, step: step, state: "running")
  end

  test "serialises the latest action call without arguments" do
    ActionCall.create!(step_run: @step_run, target_type: "mcp_tool", mcp_server: @server, tool_name: "create_invoice",
                       effect: "read", arguments: { "customer" => "c_42" }, attempted_at: 5.seconds.ago,
                       config_item_names: [ "BILLING_KEY" ]).finish!(outcome: "failed", error: "first")
    latest = ActionCall.create!(step_run: @step_run, target_type: "mcp_tool", mcp_server: @server,
                                tool_name: "create_invoice", effect: "write", arguments: { "customer" => "c_42" },
                                attempted_at: 2.seconds.ago, config_item_names: [ "BILLING_KEY" ])
    latest.finish!(outcome: "unknown", error: "Timed out")
    @step_run.mark_failed!("Timed out", error_category: :action_outcome_unknown)

    json = StepRunResource.new(@step_run.reload).to_h
    call = json["actionCall"]

    assert_equal({ "targetType" => "mcp_tool", "serverName" => "Billing", "toolName" => "create_invoice",
                   "effect" => "write", "outcome" => "unknown", "durationMs" => latest.duration_ms,
                   "error" => "Timed out" }, call)
    assert_equal "action_outcome_unknown", json["errorCategory"]
    assert_no_match(/BILLING_KEY|digest|c_42/, call.to_json)
  end

  test "an action that has not called yet, and any other step, has no action call" do
    assert_nil StepRunResource.new(@step_run).to_h["actionCall"]
    assert_nil StepRunResource.new(create(:step_run, workflow_run: @run)).to_h["actionCall"]
  end

  test "a Wrapper call names the Wrapper" do
    tool = create(:tool, scope: @project, display_name: "Ship Parcel")
    ActionCall.create!(step_run: @step_run, target_type: "wrapper", tool: tool, tool_name: tool.name, effect: "write",
                       arguments: {}, attempted_at: Time.current)

    call = StepRunResource.new(@step_run.reload).to_h["actionCall"]

    assert_equal [ "wrapper", nil, "Ship Parcel", nil ], call.values_at("targetType", "serverName", "toolName", "outcome")
  end

  test "a REST call names its connector, method and path, and keeps the operation name once it is deleted" do
    operation = create(:api_operation, api_connector: create(:api_connector, scope: @project, name: "Payments"),
                                       name: "list_charges", path: "/charges")
    ActionCall.create!(step_run: @step_run, target_type: "rest_operation", api_operation: operation,
                       tool_name: operation.name, effect: "read", arguments: {}, attempted_at: Time.current)

    call = StepRunResource.new(@step_run.reload).to_h["actionCall"]
    assert_equal [ "rest_operation", "Payments", "GET /charges" ], call.values_at("targetType", "serverName", "toolName")
    assert_equal "Payments · GET /charges", ActionCall.sole.target_label

    operation.destroy!

    assert_equal "the REST connector · list_charges", ActionCall.sole.target_label
  end
end

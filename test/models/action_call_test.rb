# frozen_string_literal: true

require "test_helper"

class ActionCallTest < ActiveSupport::TestCase
  setup do
    @step_run = create(:step_run)
  end

  test "stores no arguments, only their digest" do
    arguments = { "b" => "secret-ish", "a" => { "d" => 1, "c" => 2 } }

    call = ActionCall.create!(step_run: @step_run, target_type: "mcp_tool", tool_name: "create_invoice", effect: "write",
                              arguments: arguments, attempted_at: Time.current, config_item_names: [ "BILLING_KEY" ])

    assert_equal Digest::SHA256.hexdigest('{"a":{"c":2,"d":1},"b":"secret-ish"}'), call.reload.arguments_digest
    assert_equal ActionCall.digest(arguments.to_a.reverse.to_h), call.arguments_digest
    assert_no_match(/secret-ish/, call.attributes.to_json)
    assert_empty ActionCall.column_names.grep(/argument(?!s_digest)|result|value|token|header/)
    assert_equal [ "BILLING_KEY" ], call.config_item_names
  end

  test "takes its tenant from the step run's project" do
    call = ActionCall.create!(step_run: @step_run, target_type: "wrapper", effect: "write", arguments: {},
                              attempted_at: Time.current)
    project = @step_run.workflow_run.project

    assert_equal [ project.id, project.company_id ], [ call.project_id, call.company_id ]
  end

  test "records how a call finished" do
    call = ActionCall.create!(step_run: @step_run, target_type: "mcp_tool", tool_name: "t", effect: "read",
                              arguments: {}, attempted_at: 2.seconds.ago)

    call.finish!(outcome: "failed", error: "rejected")

    assert_equal [ "failed", "rejected" ], [ call.outcome, call.error ]
    assert_operator call.duration_ms, :>=, 2000
    assert_not_nil call.finished_at
  end

  test "validates target, effect and outcome" do
    call = ActionCall.new(step_run: @step_run, target_type: "shell", effect: "loud", outcome: "maybe", attempted_at: Time.current)

    assert_not call.valid?
    assert_equal %i[effect outcome target_type], call.errors.attribute_names.sort
  end

  test "a non-read call that never finished counts as resendable" do
    call = ->(effect) do
      ActionCall.create!(step_run: create(:step_run), target_type: "mcp_tool", tool_name: "t", effect: effect,
                         arguments: {}, attempted_at: Time.current)
    end
    unfinished = call.call("write")
    call.call("read")
    call.call("write").finish!(outcome: "failed")

    assert_equal [ unfinished ], ActionCall.resendable.to_a
  end

  test "labels fall back to the stored tool name when the target is gone" do
    call = ->(type) { ActionCall.new(step_run: @step_run, target_type: type, tool_name: "gone") }

    assert_equal [ nil, "gone", "the server · gone" ],
                 [ call.("mcp_tool").server_name, call.("mcp_tool").target_name, call.("mcp_tool").target_label ]
    assert_equal [ nil, "gone", "gone" ], [ call.("wrapper").server_name, call.("wrapper").target_name, call.("wrapper").target_label ]
    assert_equal "the REST connector · gone", call.("rest_operation").target_label
  end
end

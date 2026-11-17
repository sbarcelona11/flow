# frozen_string_literal: true

require "test_helper"

module Activities
  module Workflow
    class ActionActivitiesTest < ActiveSupport::TestCase
      SECRET = "sk-live-9f8e7d6c5b4a"

      setup do
        @company = create(:company)
        @user = create(:user, company: @company)
        @project = create(:project, company: @company, owner: @user)
        @workflow = create(:workflow, scope: @project)
        @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
        @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing",
                                                          snapshot_tools: [ { "name" => "create_invoice" },
                                                                            { "name" => "list_invoices",
                                                                              "annotations" => { "readOnlyHint" => true } } ])
      end

      def action_run(effect: "write", tool: "create_invoice", arguments: {}, config: nil, depends_on: [])
        config ||= { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => tool,
                     "arguments" => arguments, "effect" => effect }
        step = with_feature(:workflow_action_steps, true, company: @company) do
          create(:step, workflow: @workflow, kind: "action", kind_config: config, depends_on_step_ids: depends_on)
        end
        create(:step_run, workflow_run: @run, step: step)
      end

      def approved_irreversible_run(approval_state: :completed)
        approval = create(:step, workflow: @workflow, kind: "approval", kind_config: { "timeout_seconds" => 3600 })
        create(:step_run, workflow_run: @run, step: approval, state: approval_state)
        action_run(effect: "irreversible", depends_on: [ approval.id ])
      end

      def start(step_run) = StartActionActivity.new.execute("step_run_id" => step_run.id)

      def succeeded(structured: { "id" => 7 }, text: "created")
        ::MCP::ToolCaller::Result.new(ok: true, structured: structured, text: text, unknown: false, config_item_names: [])
      end

      def assert_failed(step_run, category)
        step_run.reload
        assert_equal "failed", step_run.state
        assert_equal category, step_run.error_category
      end

      test "an MCP action writes its result as the step's output" do
        @run.update!(shared_context: { "customer" => { "id" => "c_42" } })
        step_run = action_run(arguments: { "customer" => "{{context:customer.id}}" })
        ::MCP::ToolCaller.expects(:call).with(server: @server, tool: "create_invoice",
                                            arguments: { "customer" => "c_42" }, user: @user).returns(succeeded)

        result = start(step_run)

        assert_equal({ "mode" => "done", "outcome" => "completed" }, result)
        step_run.reload
        assert_equal "completed", step_run.state
        assert_match(/\ACalled Billing · create_invoice \(write\) in \d+ ms\z/, step_run.step_note)
        assert step_run.action_attempted_at
        asset = @run.workflow_run_assets.sole
        assert_equal "result.json", asset.name
        assert_equal({ "id" => 7 }, JSON.parse(asset.file.read))
        call = ActionCall.sole
        assert_equal [ "succeeded", "mcp_tool", "create_invoice", "write" ],
                     [ call.outcome, call.target_type, call.tool_name, call.effect ]
        assert_equal ActionCall.digest({ "customer" => "c_42" }), call.arguments_digest
        assert call.finished_at
      end

      test "an MCP action without structured content writes its text" do
        step_run = action_run(config: { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "create_invoice",
                                        "arguments" => {}, "effect" => "write", "output_name" => "invoice.md" })
        ::MCP::ToolCaller.stubs(:call).returns(succeeded(structured: nil, text: "Invoice 7 created"))

        start(step_run)

        assert_equal "Invoice 7 created", @run.workflow_run_assets.find_by!(name: "invoice.md").file.read
      end

      test "the recorded config is used over the live step" do
        step_run = action_run(tool: "create_invoice")
        recorded = step_run.step.kind_config.merge("tool" => "list_invoices", "effect" => "read")
        ::MCP::ToolCaller.expects(:call).with(has_entry(:tool, "list_invoices")).returns(succeeded)

        StartActionActivity.new.execute("step_run_id" => step_run.id, "kind_config" => recorded)

        assert_equal "read", ActionCall.sole.effect
      end

      test "a second start of an irreversible action fails as outcome unknown without calling" do
        step_run = approved_irreversible_run
        ::MCP::ToolCaller.stubs(:call).raises(Interrupt)
        assert_raises(Interrupt) { start(step_run) }
        ::MCP::ToolCaller.unstub(:call)
        ::MCP::ToolCaller.expects(:call).never

        result = start(step_run)

        assert_equal({ "mode" => "done", "outcome" => "failed" }, result)
        assert_failed(step_run, "action_outcome_unknown")
        assert_equal "This action may already have run, so it was not sent again. " \
                     "Check Billing · create_invoice before retrying.", step_run.error_message
        assert_equal "unknown", ActionCall.sole.outcome
      end

      test "a second start of a read action calls again" do
        step_run = action_run(effect: "read", tool: "list_invoices")
        ::MCP::ToolCaller.stubs(:call).raises(Interrupt)
        assert_raises(Interrupt) { start(step_run) }
        ::MCP::ToolCaller.unstub(:call)
        ::MCP::ToolCaller.expects(:call).once.returns(succeeded)

        result = start(step_run)

        assert_equal "completed", result["outcome"]
        assert_equal 2, ActionCall.where(step_run: step_run).count
      end

      test "one step run records one side-effecting call at most" do
        step_run = action_run
        ActionCall.create!(step_run: step_run, target_type: "mcp_tool", effect: "write", attempted_at: Time.current)

        assert_raises(ActiveRecord::RecordNotUnique) do
          ActionCall.create!(step_run: step_run, target_type: "mcp_tool", effect: "write", attempted_at: Time.current)
        end
      end

      test "a drifted tool fails before calling" do
        step_run = action_run
        @server.update!(tool_drift: { "changed" => [ "create_invoice" ] })
        ::MCP::ToolCaller.expects(:call).never

        result = start(step_run)

        assert_equal({ "mode" => "done", "outcome" => "failed" }, result)
        assert_failed(step_run, "action_tool_drifted")
        assert_match(/create_invoice/, step_run.error_message)
        assert_nil step_run.action_attempted_at
        assert_equal 0, ActionCall.count
      end

      test "a removed tool fails as target missing" do
        step_run = action_run
        @server.update!(enabled: false)
        ::MCP::ToolCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_target_missing")
      end

      test "a server of another project fails as target missing" do
        other = create(:mcp_server, :with_tool_schemas, scope: create(:project, company: @company, owner: @user),
                                                        snapshot_tools: [ { "name" => "create_invoice" } ])
        step_run = action_run
        recorded = step_run.step.kind_config.merge("mcp_server_id" => other.id)
        ::MCP::ToolCaller.expects(:call).never

        StartActionActivity.new.execute("step_run_id" => step_run.id, "kind_config" => recorded)

        assert_failed(step_run, "action_target_missing")
        assert_nil step_run.reload.action_attempted_at
      end

      test "a tool whose own effect became stricter than the step's fails before calling" do
        step_run = action_run
        tools = @server.tool_snapshot["tools"].map do |tool|
          tool["name"] == "create_invoice" ? tool.merge("annotations" => { "destructiveHint" => true }) : tool
        end
        @server.update_columns(tool_snapshot: @server.tool_snapshot.merge("tools" => tools))
        ::MCP::ToolCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_failed")
        assert_equal "The tool's own effect is now irreversible, stricter than this step's write. " \
                     "Update the step before running it.", step_run.error_message
      end

      test "an irreversible action without an approval given in this run is not sent" do
        step_run = approved_irreversible_run(approval_state: :skipped)
        ::MCP::ToolCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_not_approved")
        assert_equal "This action needs an approval that was given in this run.", step_run.error_message
      end

      test "an irreversible action after an approval given in this run is sent" do
        step_run = approved_irreversible_run
        ::MCP::ToolCaller.expects(:call).returns(succeeded)

        assert_equal "completed", start(step_run)["outcome"]
      end

      test "the recorded dependencies decide the approval, not the live step's" do
        step_run = approved_irreversible_run
        approval_id = step_run.step.depends_on_step_ids.first
        step_run.step.update_columns(depends_on_step_ids: [])
        ::MCP::ToolCaller.expects(:call).returns(succeeded)

        result = StartActionActivity.new.execute("step_run_id" => step_run.id, "depends_on_step_ids" => [ approval_id ])

        assert_equal "completed", result["outcome"]
      end

      test "an approval given by a step since deleted does not count" do
        step_run = approved_irreversible_run
        Step.find(step_run.step.depends_on_step_ids.first).update_columns(deleted_at: Time.current)
        ::MCP::ToolCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_not_approved")
      end

      test "a missing context key fails as invalid arguments" do
        step_run = action_run(arguments: { "customer" => "{{context:customer.id}}" })
        ::MCP::ToolCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_invalid_arguments")
        assert_match(/customer\.id/, step_run.error_message)
      end

      test "arguments that break the tool's schema once resolved fail as invalid arguments" do
        @server.update!(tool_snapshot: @server.tool_snapshot.merge("tools" => [
          @server.tool_snapshot["tools"].first.merge(
            "input_schema" => { "type" => "object", "properties" => { "amount" => { "type" => "integer" } } }
          )
        ]))
        @run.update!(shared_context: { "amount" => "lots" })
        step_run = action_run(arguments: { "amount" => "{{context:amount}}" })
        ::MCP::ToolCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_invalid_arguments")
      end

      test "a per-user server with no run owner fails as auth required" do
        resolve_hosts_publicly!
        @server.update!(auth_type: :oauth, credential_scope: :per_user)
        @run.update!(user: nil)
        step_run = action_run

        start(step_run)

        assert_failed(step_run, "action_auth_required")
        assert_match(/Billing/, step_run.error_message)
        assert_equal "failed", ActionCall.sole.outcome
      end

      test "a failed call fails with the caller's message" do
        step_run = action_run
        ::MCP::ToolCaller.stubs(:call).returns(
          ::MCP::ToolCaller::Result.new(ok: false, error: "Customer not found", unknown: false, config_item_names: [])
        )

        start(step_run)

        assert_failed(step_run, "action_failed")
        assert_equal "Customer not found", step_run.error_message
        assert_equal [ "failed", "Customer not found" ], [ ActionCall.sole.outcome, ActionCall.sole.error ]
      end

      test "a call with an unknown outcome fails as outcome unknown" do
        step_run = action_run
        ::MCP::ToolCaller.stubs(:call).returns(
          ::MCP::ToolCaller::Result.new(ok: false, error: "Billing timed out", unknown: true, config_item_names: [])
        )

        start(step_run)

        assert_failed(step_run, "action_outcome_unknown")
        assert_match(/Billing timed out/, step_run.error_message)
        assert_match(/Check Billing · create_invoice before retrying/, step_run.error_message)
        assert_equal "unknown", ActionCall.sole.outcome
      end

      test "an output over the size cap fails as output too large" do
        step_run = action_run
        ::MCP::ToolCaller.stubs(:call).returns(succeeded(structured: nil, text: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1)))

        start(step_run)

        assert_failed(step_run, "action_output_too_large")
        assert_equal 0, @run.workflow_run_assets.count
      end

      test "a tool that ran but whose output could not be saved records the call as succeeded" do
        step_run = action_run
        ::MCP::ToolCaller.stubs(:call).returns(succeeded(structured: 42))

        start(step_run)

        assert_failed(step_run, "action_failed")
        assert_equal "The tool ran, but its output could not be saved.", step_run.error_message
        assert_equal "succeeded", ActionCall.sole.outcome
        assert_equal 0, @run.workflow_run_assets.count
      end

      test "an output that could not be saved is logged by its class with the MCP call's secrets redacted" do
        step_run = action_run
        redactor = ->(text) { text.gsub(SECRET, "[redacted]") }
        ::MCP::ToolCaller.stubs(:call).returns(succeeded.tap { |result| result.redactor = redactor })
        ::Actions::OutputWriter.stubs(:write!).raises(IOError, "upload failed: X-Api-Key: #{SECRET}")

        logged = capture_log { start(step_run) }

        assert_failed(step_run, "action_failed")
        assert_includes logged, "IOError: upload failed: X-Api-Key: [redacted]"
        assert_not_includes logged, SECRET
      end

      test "a Wrapper output that could not be saved is logged by its class with its config secrets redacted" do
        create(:config_item, scope: @project, name: "EXPORT_KEY", item_type: :secret, value: SECRET)
        tool = create(:tool, scope: @project, required_config_items: [ "EXPORT_KEY" ])
        step_run = action_run(config: { "target" => "wrapper", "tool_id" => tool.id, "arguments" => {}, "effect" => "write" })
        mock_temporal_start
        tool_result = ToolResult.find(start(step_run)["tool_result_id"])
        tool_result.complete!(exit_code: 0, stdout: "done", stderr: "", duration_ms: 10)
        ::Actions::OutputWriter.stubs(:write!).raises(IOError, "upload failed: token=#{SECRET}")

        logged = capture_log { FinishActionActivity.new.execute("step_run_id" => step_run.id) }

        assert_failed(step_run, "action_failed")
        assert_includes logged, "IOError: upload failed: token=[redacted]"
        assert_not_includes logged, SECRET
      end

      def capture_log
        io = StringIO.new
        original = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        yield
        io.string
      ensure
        Rails.logger = original
      end

      test "a cancelled step run is left alone" do
        step_run = action_run
        step_run.mark_cancelled!
        ::MCP::ToolCaller.expects(:call).never

        result = start(step_run)

        assert_equal({ "mode" => "done", "outcome" => "cancelled" }, result)
        assert_equal "cancelled", step_run.reload.state
        assert_nil step_run.action_attempted_at
        assert_equal 0, ActionCall.count
      end

      test "no secret value appears in the step note, error or action call" do
        create(:config_item, scope: @project, name: "BILLING_KEY", item_type: :secret, value: SECRET)
        @server.update!(headers: { "X-Api-Key" => "config_item:BILLING_KEY" })
        failing = action_run
        ::MCP::ToolCaller.stubs(:call).raises(RuntimeError, "request failed: X-Api-Key: #{SECRET}")

        start(failing)

        assert_failed(failing, "action_outcome_unknown")
        ::MCP::ToolCaller.unstub(:call)
        passing = action_run
        ::MCP::ToolCaller.stubs(:call).returns(succeeded(structured: nil, text: "ok"))
        start(passing)

        [ failing, passing ].each do |step_run|
          step_run.reload
          assert_not_includes step_run.error_message.to_s, SECRET
          assert_not_includes step_run.step_note.to_s, SECRET
        end
        ActionCall.find_each { |call| assert_not_includes call.attributes.to_json, SECRET }
      end

      test "a Wrapper action starts the container without a session and finishes from its result" do
        tool = create(:tool, scope: @project, name: "count_rows",
                             input_schema: { "type" => "object", "properties" => { "table" => { "type" => "string" } } })
        step_run = action_run(config: { "target" => "wrapper", "tool_id" => tool.id,
                                        "arguments" => { "table" => "orders" }, "effect" => "write" })
        started = options = nil
        TemporalService.expects(:start_workflow).with do |_workflow, input, opts|
          started = input
          options = opts
        end.returns(ok: true, workflow_id: "action-step-run", run_id: "r")

        result = start(step_run)

        tool_result = ToolResult.find(result["tool_result_id"])
        assert_equal({ "mode" => "async", "tool_result_id" => tool_result.id,
                       "deadline_seconds" => ContainerStrategies::ToolStrategy::DEFAULT_TIMEOUT + 120 }, result)
        assert_equal [ step_run, nil ], [ tool_result.step_run, tool_result.terminal_session ]
        assert_equal({ "table" => "orders" }, started[:parameters])
        assert_equal tool.id, started[:tool_id]
        assert_equal [ "action-step-run-#{step_run.id}", true ], [ options[:id], options[:reject_duplicate] ]
        assert_equal "running", step_run.reload.state

        assert_equal({ "state" => "processing" },
                     ActionStatusActivity.new.execute("tool_result_id" => tool_result.id))
        tool_result.complete!(exit_code: 0, stdout: '{"rows": 3}', stderr: "", duration_ms: 1200)
        assert_equal({ "state" => "completed" },
                     ActionStatusActivity.new.execute("tool_result_id" => tool_result.id))

        finished = FinishActionActivity.new.execute("step_run_id" => step_run.id, "tool_result_id" => tool_result.id)

        assert_equal({ "outcome" => "completed" }, finished)
        assert_equal "completed", step_run.reload.state
        assert_match(/\ACalled Count Rows \(write\) in \d+ ms\z/, step_run.step_note)
        assert_equal({ "rows" => 3 }, JSON.parse(@run.workflow_run_assets.sole.file.read))
        assert_equal [ "succeeded", "wrapper", tool.id ], [ ActionCall.sole.outcome, ActionCall.sole.target_type, ActionCall.sole.tool_id ]
      end

      test "a Wrapper that exits nonzero fails with the start of its stderr" do
        tool = create(:tool, scope: @project)
        step_run = action_run(config: { "target" => "wrapper", "tool_id" => tool.id, "arguments" => {}, "effect" => "write" })
        mock_temporal_start
        tool_result = ToolResult.find(start(step_run)["tool_result_id"])
        tool_result.complete!(exit_code: 2, stdout: "", stderr: "boom #{'e' * 600}", duration_ms: 10)

        finished = FinishActionActivity.new.execute("step_run_id" => step_run.id)

        assert_equal({ "outcome" => "failed" }, finished)
        assert_failed(step_run, "action_failed")
        assert_equal "boom #{'e' * 495}", step_run.error_message
        assert_equal "failed", ActionCall.sole.outcome
      end

      test "a Wrapper still running at its deadline fails as outcome unknown" do
        tool = create(:tool, scope: @project)
        step_run = action_run(config: { "target" => "wrapper", "tool_id" => tool.id, "arguments" => {}, "effect" => "write" })
        mock_temporal_start
        start(step_run)

        finished = FinishActionActivity.new.execute("step_run_id" => step_run.id)

        assert_equal({ "outcome" => "failed" }, finished)
        assert_failed(step_run, "action_outcome_unknown")
        assert_equal "unknown", ActionCall.sole.outcome
      end

      test "a Wrapper whose step was skipped while it ran closes its call as unknown and reports skipped" do
        step_run = wrapper_run
        mock_temporal_start
        start(step_run)
        step_run.update_columns(state: "skipped")

        finished = FinishActionActivity.new.execute("step_run_id" => step_run.id, "stopped" => "skipped")

        assert_equal({ "outcome" => "skipped" }, finished)
        assert_equal "skipped", step_run.reload.state
        call = ActionCall.sole
        assert_equal "unknown", call.outcome
        assert_equal "The step ended as skipped while Export ran. This action may have run. Check Export before retrying.",
                     call.error
        assert_equal 0, @run.workflow_run_assets.count
      end

      test "a Wrapper stopped by a cancel before its step run ended leaves the step run alone" do
        step_run = wrapper_run
        mock_temporal_start
        start(step_run)

        finished = FinishActionActivity.new.execute("step_run_id" => step_run.id, "stopped" => "cancelled")

        assert_equal({ "outcome" => "cancelled" }, finished)
        assert_equal "running", step_run.reload.state
        assert_equal "unknown", ActionCall.sole.outcome
      end

      def rest_operation(**attrs)
        @rest_operation ||= create(:api_operation, :with_path_param,
                                   api_connector: create(:api_connector, scope: @project, name: "Payments"),
                                   name: "charge", method: "POST", path: "/charges/{id}", effect: "write", **attrs)
      end

      def rest_run(effect: "write", arguments: { "path" => { "id" => "ch_1" } }, depends_on: [])
        action_run(config: { "target" => "rest_operation", "api_operation_id" => rest_operation.id,
                             "arguments" => arguments, "effect" => effect }, depends_on: depends_on)
      end

      def rest_result(ok: true, structured: nil, text: nil, error: nil, unknown: false, status: 200)
        ::Rest::OperationCaller::Result.new(ok: ok, structured: structured, text: text, error: error, unknown: unknown,
                                            status: status, config_item_names: [ "PAYMENTS_TOKEN" ], redactor: nil)
      end

      test "a REST action writes the JSON body as the output" do
        @run.update!(shared_context: { "charge" => "ch_42" })
        step_run = rest_run(arguments: { "path" => { "id" => "{{context:charge}}" } })
        ::Rest::OperationCaller.expects(:call).with(operation: rest_operation, arguments: { "path" => { "id" => "ch_42" } },
                                                    project: @project)
                               .returns(rest_result(structured: { "id" => "ch_42", "paid" => true }))

        result = start(step_run)

        assert_equal({ "mode" => "done", "outcome" => "completed" }, result)
        step_run.reload
        assert_match(%r{\ACalled Payments · POST /charges/\{id\} \(write\) in \d+ ms\z}, step_run.step_note)
        assert_equal({ "id" => "ch_42", "paid" => true }, JSON.parse(@run.workflow_run_assets.sole.file.read))
        call = ActionCall.sole
        assert_equal [ "succeeded", "rest_operation", rest_operation.id, "charge", [ "PAYMENTS_TOKEN" ] ],
                     [ call.outcome, call.target_type, call.api_operation_id, call.tool_name, call.config_item_names ]
        assert_equal "Payments · POST /charges/{id}", call.target_label
      end

      test "a REST action without a JSON body writes its text" do
        step_run = rest_run
        ::Rest::OperationCaller.stubs(:call).returns(rest_result(text: "accepted"))

        start(step_run)

        assert_equal "accepted", @run.workflow_run_assets.sole.file.read
      end

      test "a REST action whose operation effect was raised fails before calling" do
        step_run = rest_run
        rest_operation.update!(effect: "irreversible")
        ::Rest::OperationCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_failed")
        assert_equal "The operation's own effect is now irreversible, stricter than this step's write. " \
                     "Update the step before running it.", step_run.error_message
        assert_nil step_run.action_attempted_at
        assert_equal 0, ActionCall.count
      end

      test "a 503 marks the action outcome unknown and a second start does not resend" do
        step_run = rest_run
        ::Rest::OperationCaller.expects(:call).once.returns(
          rest_result(ok: false, unknown: true, status: 503, error: "Payments answered 503 to POST /charges/{id}: down")
        )

        start(step_run)

        assert_failed(step_run, "action_outcome_unknown")
        assert_equal "Payments answered 503 to POST /charges/{id}: down. This action may have run. " \
                     "Check Payments · POST /charges/{id} before retrying.", step_run.error_message
        step_run.update_columns(state: "running", error_category: nil)

        start(step_run)

        assert_failed(step_run, "action_outcome_unknown")
        assert_equal "This action may already have run, so it was not sent again. " \
                     "Check Payments · POST /charges/{id} before retrying.", step_run.error_message
        assert_equal [ "unknown" ], ActionCall.pluck(:outcome)
      end

      test "a 4xx fails the REST action with the status and the answer's excerpt" do
        step_run = rest_run
        ::Rest::OperationCaller.stubs(:call).returns(
          rest_result(ok: false, status: 422, error: "Payments answered 422 to POST /charges/{id}: amount is required")
        )

        start(step_run)

        assert_failed(step_run, "action_failed")
        assert_equal "Payments answered 422 to POST /charges/{id}: amount is required", step_run.error_message
        assert_equal "failed", ActionCall.sole.outcome
      end

      test "a REST action on an archived connector or a disabled operation fails as target missing" do
        archived = rest_run
        rest_operation.api_connector.archive!
        disabled = create(:step_run, workflow_run: @run, step: archived.step)
        ::Rest::OperationCaller.expects(:call).never

        start(archived)
        rest_operation.api_connector.unarchive!
        rest_operation.update!(enabled: false)
        start(disabled)

        [ archived, disabled ].each do |step_run|
          assert_failed(step_run, "action_target_missing")
          assert_nil step_run.action_attempted_at
        end
        assert_equal 0, ActionCall.count
      end

      test "an irreversible REST action without an approval given in this run is not sent" do
        approval = create(:step, workflow: @workflow, kind: "approval", kind_config: { "timeout_seconds" => 3600 })
        create(:step_run, workflow_run: @run, step: approval, state: :skipped)
        step_run = rest_run(effect: "irreversible", depends_on: [ approval.id ])
        ::Rest::OperationCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_not_approved")
      end

      test "a REST action whose arguments break the operation's schema is not sent" do
        step_run = rest_run(arguments: { "path" => { "id" => "ch_1" } })
        step_run.step.update_columns(kind_config: step_run.step.kind_config.merge("arguments" => { "path" => {} }))
        ::Rest::OperationCaller.expects(:call).never

        start(step_run)

        assert_failed(step_run, "action_invalid_arguments")
      end

      test "a REST connector missing a config item fails naming it" do
        step_run = rest_run
        ::Rest::OperationCaller.stubs(:call).raises(::ConfigItems::ReferenceResolver::Missing, "PAYMENTS_TOKEN")

        start(step_run)

        assert_failed(step_run, "action_failed")
        assert_equal "Payments needs config item PAYMENTS_TOKEN does not exist in this project.", step_run.error_message
        assert_equal "failed", ActionCall.sole.outcome
        assert_equal [ "PAYMENTS_TOKEN" ], ActionCall.sole.config_item_names
      end

      def wrapper_run
        tool = create(:tool, scope: @project, display_name: "Export")
        action_run(config: { "target" => "wrapper", "tool_id" => tool.id, "arguments" => {}, "effect" => "write" })
      end

      test "a Wrapper that Temporal refused before queuing fails as not started" do
        step_run = wrapper_run
        TemporalService.stubs(:start_workflow).returns(ok: false, error: "Temporal is disabled")

        assert_equal({ "mode" => "done", "outcome" => "failed" }, start(step_run))
        assert_failed(step_run, "action_failed")
        assert_equal "failed", ActionCall.sole.outcome
      end

      test "a Wrapper start that failed after reaching Temporal fails as outcome unknown" do
        step_run = wrapper_run
        TemporalService.stubs(:start_workflow)
                       .returns(ok: false, error: "deadline exceeded", error_class: "Temporalio::Error::RPCError")

        assert_equal({ "mode" => "done", "outcome" => "failed" }, start(step_run))
        assert_failed(step_run, "action_outcome_unknown")
        assert_equal "Export may have started. Check it before retrying.", step_run.error_message
        assert_equal "unknown", ActionCall.sole.outcome
      end

      test "a Wrapper that fails while it is prepared fails before reaching Temporal" do
        step_run = wrapper_run
        ContainerStrategies::CustomToolStrategy.stubs(:new).raises(ArgumentError, "Tool requires docker_image")
        TemporalService.expects(:start_workflow).never

        assert_equal({ "mode" => "done", "outcome" => "failed" }, start(step_run))
        assert_failed(step_run, "action_failed")
        assert_equal "ArgumentError while preparing Export", step_run.error_message
        assert_equal "failed", ActionCall.sole.outcome
      end
    end
  end
end

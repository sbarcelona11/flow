# frozen_string_literal: true

require "test_helper"

module Actions
  class PipelineTest < ActiveSupport::TestCase
    Connection = Data.define(:id, :name, :project)
    GOVERNANCE_TABLES = %w[step_runs action_calls tool_results workflow_run_assets].freeze

    setup do
      @company = create(:company)
      @user = create(:user, company: @company)
      @project = create(:project, company: @company, owner: @user)
      @workflow = create(:workflow, scope: @project)
      @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
      @calls = []
    end

    teardown { Connectors::Registry.reset! }

    def register_probe(base_effect: "write", result: Connectors::Result.new(ok: true, structured: { "pong" => true }),
                       async: false, scoped: true, &on_call)
      connection = Connection.new(id: 7, name: "Probe", project: @project)
      calls = @calls
      operation = Connectors::Operation.new(key: "ping", name: "ping", description: nil, input_schema: {}, output_schema: nil,
                                            base_effect: base_effect, drifted: false)
      probe = Class.new(Connectors::Transport) do
        transport :pipeline_probe, target: "pipeline_probe_operation"

        define_method(:async?) { async }
        define_method(:scope_of) { |c| c.project } if scoped

        define_method(:connections) { |project| project == connection.project ? [ connection ] : [] }
        define_method(:connection_for) { |config, project| connections(project).find { |c| c.id == config["probe_id"] } }
        define_method(:operations) { |_connection| [ operation ] }
        define_method(:owner) { |c| c&.name }
        define_method(:label) { |c, op| "#{owner(c)} · #{op.name}" }
        define_method(:call) do |connection:, operation:, arguments:, context:|
          calls << { connection: connection, operation: operation, arguments: arguments, context: context }
          on_call&.call(context)
          result
        end
      end
      Connectors::Registry.reset!
      Connectors::Registry.stubs(:discovered_transports).returns([ probe ])
    end

    def probe_config(effect: "write")
      { "target" => "pipeline_probe_operation", "probe_id" => 7, "arguments" => { "q" => "hi" }, "effect" => effect }
    end

    def step_run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))

    def start(step_run, config, depends_on: []) = Pipeline.start(step_run: step_run, kind_config: config, depends_on_step_ids: depends_on)

    def assert_failed(step_run, category, message = nil)
      step_run.reload
      assert_equal [ "failed", category ], [ step_run.state, step_run.error_category ]
      assert_equal message, step_run.error_message if message
    end

    test "a transport found by discovery runs through the pipeline without the pipeline knowing its key" do
      register_probe
      run = step_run

      result = start(run, probe_config)

      assert_equal({ "mode" => "done", "outcome" => "completed" }, result)
      assert_equal [ { "q" => "hi" } ], @calls.pluck(:arguments)
      run.reload
      assert run.action_attempted_at
      assert_match(/\ACalled Probe · ping \(write\) in \d+ ms\z/, run.step_note)
      assert_equal({ "pong" => true }, JSON.parse(@run.workflow_run_assets.sole.file.read))
      call = ActionCall.sole
      assert_equal [ "succeeded", "pipeline_probe_operation", "ping", "write" ],
                   [ call.outcome, call.target_type, call.tool_name, call.effect ]
    end

    test "a discovered transport is held to the operation's own effect" do
      register_probe(base_effect: "send")
      run = step_run

      start(run, probe_config(effect: "write"))

      assert_failed(run, "action_failed", "The tool's own effect is now send, stricter than this step's write. " \
                                          "Update the step before running it.")
      assert_empty @calls
      assert_nil run.action_attempted_at
      assert_equal 0, ActionCall.count
    end

    test "a discovered transport's irreversible action needs an approval given in this run" do
      register_probe
      approval = create(:step, workflow: @workflow, kind: "approval", kind_config: { "timeout_seconds" => 3600 })
      create(:step_run, workflow_run: @run, step: approval, state: :skipped)
      run = step_run

      start(run, probe_config(effect: "irreversible"), depends_on: [ approval.id ])

      assert_failed(run, "action_not_approved", "This action needs an approval that was given in this run.")
      assert_empty @calls
    end

    test "a discovered transport's side-effecting call is sent at most once" do
      register_probe { raise Interrupt if @calls.one? }
      run = step_run
      assert_raises(Interrupt) { start(run, probe_config) }

      result = start(run, probe_config)

      assert_equal({ "mode" => "done", "outcome" => "failed" }, result)
      assert_equal 1, @calls.size
      assert_failed(run, "action_outcome_unknown", "This action may already have run, so it was not sent again. " \
                                                   "Check Probe · ping before retrying.")
      assert_equal "unknown", ActionCall.sole.outcome
    end

    test "the pipeline commits governance state before the call and writes none of it during the call" do
      writes = []
      inside_call = false
      register_probe do |context|
        inside_call = true
        assert_equal({ step_run_attempted: true, call_open: true },
                     { step_run_attempted: StepRun.find(context.step_run_id).action_attempted_at.present?,
                       call_open: ActionCall.where(step_run_id: context.step_run_id, outcome: nil).exists? })
      ensure
        inside_call = false
      end
      run = step_run
      record = lambda do |*, payload|
        sql = payload[:sql].to_s
        writes << sql if inside_call && sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/i) &&
                         GOVERNANCE_TABLES.any? { |table| sql.include?(%("#{table}")) }
      end

      ActiveSupport::Notifications.subscribed(record, "sql.active_record") { start(run, probe_config) }

      assert_equal %i[project user step_run_id run_id tool_result_id], Connectors::Context.members
      context = @calls.sole[:context]
      assert_equal [ @project, @user, run.id, @run.id, nil ],
                   [ context.project, context.user, context.step_run_id, context.run_id, context.tool_result_id ]
      assert_not @calls.sole.values.any? { |value| value.is_a?(ActiveRecord::Base) }
      assert_empty writes
      assert_equal "completed", run.reload.state
      assert_equal "succeeded", ActionCall.sole.outcome
    end

    test "an unregistered transport fails as action_target_missing" do
      run = step_run

      result = start(run, { "target" => "carrier_pigeon", "arguments" => {}, "effect" => "write" })

      assert_equal({ "mode" => "done", "outcome" => "failed" }, result)
      assert_failed(run, "action_target_missing", "The action's tool is not available in this project.")
      assert_nil run.action_attempted_at
      assert_equal 0, ActionCall.count
    end

    test "an unregistered stored target is labelled as the action's tool when a second start is refused" do
      run = step_run
      run.update!(action_attempted_at: Time.current)
      ActionCall.create!(step_run: run, target_type: "mcp_tool", effect: "write", attempted_at: run.action_attempted_at)

      start(run, { "target" => "carrier_pigeon", "arguments" => {}, "effect" => "write" })

      assert_failed(run, "action_outcome_unknown", "This action may already have run, so it was not sent again. " \
                                                   "Check the action's tool before retrying.")
    end

    test "an asynchronous transport whose connection is not a Wrapper is refused before the attempt" do
      register_probe(async: true)
      run = step_run

      result = start(run, probe_config)

      assert_equal({ "mode" => "done", "outcome" => "failed" }, result)
      assert_failed(run, "action_failed", "ActiveRecord::AssociationTypeMismatch while preparing Probe · ping")
      assert_empty @calls
      assert_nil run.action_attempted_at
      assert_equal [ 0, 0 ], [ ActionCall.count, ToolResult.count ]
    end

    test "a transport missing a required hook is refused before the attempt" do
      register_probe(scoped: false)
      run = step_run

      start(run, probe_config)

      assert_failed(run, "action_failed", "NotImplementedError while preparing Probe · ping")
      assert_empty @calls
      assert_nil run.action_attempted_at
      assert_equal 0, ActionCall.count
    end

    test "a Wrapper whose result data is JSON null fails as output not saved" do
      tool = create(:tool, scope: @project)
      run = step_run
      config = { "target" => "wrapper", "tool_id" => tool.id, "arguments" => {}, "effect" => "write" }
      mock_temporal_start
      handle = start(run, config)
      tool_result = ToolResult.find(handle["tool_result_id"])
      tool_result.complete!(exit_code: 0, stdout: "", stderr: "", duration_ms: 10)
      tool_result.update!(result_data: ToolResultUploader.upload(StringIO.new("null"), :store,
                                                                 metadata: { "filename" => "result_data.json", "size" => 4 }))

      result = Pipeline.finish(step_run: run, handle: handle.slice("tool_result_id"), stopped: nil, kind_config: config)

      assert_equal({ "outcome" => "failed" }, result)
      assert_failed(run, "action_failed", "The tool ran, but its output could not be saved.")
      assert_equal "succeeded", ActionCall.sole.outcome
    end

    test "polling a tool result reads its state without an action call" do
      tool_result = ToolResult.create!(tool: create(:tool, scope: @project), step_run: step_run,
                                       execution_id: ToolResult.generate_id, state: "processing")

      state = assert_queries_count(1) { Pipeline.status(handle: { "tool_result_id" => tool_result.id }) }

      assert_equal({ "state" => "processing" }, state)
    end
  end
end

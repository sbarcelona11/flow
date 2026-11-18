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
                       async: false, scoped: true, cost_cents: nil, &on_call)
      connection = Connection.new(id: 7, name: "Probe", project: @project)
      calls = @calls
      operation = Connectors::Operation.new(key: "ping", name: "ping", description: nil, input_schema: {}, output_schema: nil,
                                            base_effect: base_effect, drifted: false, cost_cents: cost_cents)
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

    SECRET = "s3cr3t-token-value"

    def secret_redactor = ->(text) { text.gsub(SECRET, "[redacted]") }

    test "the transport's redactor is applied to the stored output before it is written" do
      register_probe(result: Connectors::Result.new(ok: true, structured: { "echo" => "token=#{SECRET}", SECRET => [ SECRET, 1 ] },
                                                    redactor: secret_redactor))

      start(step_run, probe_config)

      stored = @run.workflow_run_assets.sole.file.read
      assert_not_includes stored, SECRET
      assert_equal({ "echo" => "token=[redacted]", "[redacted]" => [ "[redacted]", 1 ] }, JSON.parse(stored))
    end

    test "the transport's redactor is applied to a text output" do
      register_probe(result: Connectors::Result.new(ok: true, text: "token=#{SECRET}", redactor: secret_redactor))

      start(step_run, probe_config)

      assert_equal "token=[redacted]", @run.workflow_run_assets.sole.file.read
    end

    test "the transport's redactor is applied to a failure before it is stored or audited" do
      register_probe(result: Connectors::Result.new(ok: false, error: "rejected #{SECRET}", redactor: secret_redactor))
      run = step_run

      start(run, probe_config)

      assert_failed(run, "action_failed", "rejected [redacted]")
      assert_equal "rejected [redacted]", ActionCall.sole.error
    end

    test "the transport's redactor is applied to an unknown outcome" do
      register_probe(result: Connectors::Result.new(unknown: true, error: "reset #{SECRET}", redactor: secret_redactor))
      run = step_run

      start(run, probe_config)

      assert_not_includes run.reload.error_message, SECRET
      assert_not_includes ActionCall.sole.error, SECRET
    end

    test "a discovered transport's sent call is listed as resendable" do
      register_probe
      start(step_run, probe_config)

      assert_equal ActionCall.all.to_a, @run.reload.resendable_action_calls
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

    def capped_step(cap, workflow_cap: nil)
      @workflow.update!(budget_cents: workflow_cap) if workflow_cap
      @run.update_columns(budget_cents: workflow_cap)
      create(:step, workflow: @workflow, budget_cents: cap)
    end

    def spend(step, cents)
      earlier = create(:step_run, workflow_run: @run, step: step)
      ActionCall.create!(step_run: earlier, target_type: Connectors::Registry.targets.first, effect: "read", attempted_at: Time.current,
                         estimated_cost_cents: cents)
    end

    def rest_config(operation, **extra)
      { "target" => "rest_operation", "api_operation_id" => operation.id, "arguments" => {}, "effect" => "write" }.merge(extra)
    end

    def paid_operation(cost_cents)
      connector = create(:api_connector, scope: @project, name: "billing", base_url: "https://api.example.com/v1")
      create(:api_operation, api_connector: connector, name: "create_invoice", http_method: "POST", effect: "write",
                             path: "/invoices", cost_cents: cost_cents)
    end

    test "an action whose estimate would pass the step cap is refused before anything is sent" do
      resolve_hosts_publicly!
      stub = stub_request(:any, /api\.example\.com/)
      step = capped_step(100)
      spend(step, 70)
      run = create(:step_run, workflow_run: @run, step: step)

      result = start(run, rest_config(paid_operation(40)))

      assert_equal({ "mode" => "done", "outcome" => "failed" }, result)
      assert_failed(run, "budget_exceeded", "Budget exceeded: this call is estimated at $0.40 and the step has $0.30 left " \
                                            "of its $1.00 cap, so it was not sent.")
      assert_not_requested stub
      assert_nil run.action_attempted_at
      assert_equal [ 1, 70 ], [ ActionCall.count, Budgets::Ledger.new(run).step_spent_cents ]
    end

    test "a refused call records no estimate and leaves the attempt unused, so a retry under a raised cap can send" do
      resolve_hosts_publicly!
      stub = stub_request(:post, "https://api.example.com/v1/invoices").to_return(status: 200, body: "{}",
                                                                                 headers: { "Content-Type" => "application/json" })
      step = capped_step(100)
      spend(step, 70)
      operation = paid_operation(40)
      refused = create(:step_run, workflow_run: @run, step: step)
      start(refused, rest_config(operation))
      step.update!(budget_cents: 200)
      retry_run = create(:step_run, workflow_run: @run, step: step)

      start(retry_run, rest_config(operation))

      assert_equal "completed", retry_run.reload.state
      assert_requested stub, times: 1
      assert_equal [ nil, 40 ], [ ActionCall.find_by(step_run: refused)&.estimated_cost_cents, ActionCall.find_by!(step_run: retry_run).estimated_cost_cents ]
      assert_equal 110, Budgets::Ledger.new(retry_run).step_spent_cents
    end

    test "an action with no estimate runs below the cap and is refused at the cap" do
      register_probe
      step = capped_step(100)
      spend(step, 99)
      below = create(:step_run, workflow_run: @run, step: step)

      start(below, probe_config)

      assert_equal "completed", below.reload.state
      assert_nil ActionCall.find_by!(step_run: below).estimated_cost_cents

      spend(step, 1)
      at_cap = create(:step_run, workflow_run: @run, step: step)
      start(at_cap, probe_config)

      assert_failed(at_cap, "budget_exceeded")
      assert_equal 1, @calls.size
      assert_nil at_cap.action_attempted_at
      assert_equal 0, ActionCall.where(step_run: at_cap).count
    end

    test "the run cap refuses an action whose step has no cap" do
      register_probe(cost_cents: 30)
      step = capped_step(nil, workflow_cap: 100)
      spend(create(:step, workflow: @workflow), 80)
      run = create(:step_run, workflow_run: @run, step: step)

      start(run, probe_config)

      assert_failed(run, "budget_exceeded", "Budget exceeded: this call is estimated at $0.30 and the run has $0.20 left " \
                                            "of its $1.00 cap, so it was not sent.")
      assert_empty @calls
    end

    test "a block's cost can raise the operation's estimate but never lower it" do
      resolve_hosts_publicly!
      stub = stub_request(:any, /api\.example\.com/)
      operation = paid_operation(10)
      define_block(60)
      step = capped_step(50)
      raised = create(:step_run, workflow_run: @run, step: step)

      start(raised, rest_config(operation, "block" => "acme/invoice@1"))

      assert_failed(raised, "budget_exceeded", "Budget exceeded: this call is estimated at $0.60 and the step has $0.50 left " \
                                               "of its $0.50 cap, so it was not sent.")
      assert_not_requested stub

      operation.update!(cost_cents: 70)
      lower = create(:step_run, workflow_run: @run, step: capped_step(65))
      start(lower, rest_config(operation, "block" => "acme/invoice@1"))

      assert_failed(lower, "budget_exceeded", "Budget exceeded: this call is estimated at $0.70 and the step has $0.65 left " \
                                              "of its $0.65 cap, so it was not sent.")
    end

    test "a block that cannot be read adds no estimate" do
      register_probe(cost_cents: 10)
      run = create(:step_run, workflow_run: @run, step: capped_step(50))

      start(run, probe_config.merge("block" => "acme/missing@1"))

      assert_equal 10, ActionCall.find_by!(step_run: run).estimated_cost_cents
    end

    test "the attempted call records the estimate once and the ledger counts it" do
      register_probe(cost_cents: 25)
      run = create(:step_run, workflow_run: @run, step: capped_step(100))

      start(run, probe_config)

      assert_equal 25, ActionCall.find_by!(step_run: run).estimated_cost_cents
      assert_equal 25, Budgets::Ledger.new(run).step_spent_cents
    end

    test "an estimate that exactly fills the cap passes and one cent more is refused" do
      register_probe(cost_cents: 30)
      step = capped_step(100)
      spend(step, 70)
      fills = create(:step_run, workflow_run: @run, step: step)

      start(fills, probe_config)

      assert_equal "completed", fills.reload.state

      other = capped_step(100)
      spend(other, 71)
      over = create(:step_run, workflow_run: @run, step: other)
      start(over, probe_config)

      assert_failed(over, "budget_exceeded")
    end

    test "an attempted write action over budget still ends as an unknown outcome and is not sent again" do
      register_probe(cost_cents: 30) { raise Interrupt }
      step = capped_step(100)
      run = create(:step_run, workflow_run: @run, step: step)
      assert_raises(Interrupt) { start(run, probe_config) }
      spend(step, 100)

      start(run, probe_config)

      assert_failed(run, "action_outcome_unknown")
      assert_equal 1, @calls.size
    end

    test "a refused call with no estimate says what the step has spent, not a zero estimate" do
      register_probe
      step = capped_step(100)
      spend(step, 100)
      run = create(:step_run, workflow_run: @run, step: step)

      start(run, probe_config)

      assert_failed(run, "budget_exceeded", "Budget exceeded: this step has spent $1.00 of its $1.00 cap, so the call was not sent.")
    end

    test "a refusal at the run cap marks the run, one at the step cap does not" do
      register_probe(cost_cents: 500)
      run = create(:step_run, workflow_run: @run, step: capped_step(nil, workflow_cap: 100))

      start(run, probe_config)

      assert_equal "budget_exceeded", @run.reload.failure_reason

      @run.update_columns(failure_reason: nil, budget_cents: nil)
      step_capped = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow, budget_cents: 100))
      start(step_capped, probe_config)

      assert_failed(step_capped, "budget_exceeded")
      assert_nil @run.reload.failure_reason
    end

    test "two parallel action steps of a capped run cannot both pass: the first records, the second is refused" do
      register_probe(cost_cents: 60)
      @run.update_columns(budget_cents: 100)
      first = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))
      second = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))

      start(first, probe_config)
      start(second, probe_config)

      assert_equal [ "completed", "failed" ], [ first.reload.state, second.reload.state ]
      assert_equal 1, @calls.size
    end

    test "a capped run serialises its action steps with a per-run lock taken in the budget transaction, an uncapped one takes none" do
      register_probe(cost_cents: 10)
      statements = []
      record = ->(*, payload) { statements << payload[:sql].to_s if payload[:sql].to_s.include?("pg_advisory_xact_lock") }

      @run.update_columns(budget_cents: 100)
      capped = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))
      ActiveSupport::Notifications.subscribed(record, "sql.active_record") { start(capped, probe_config) }
      assert_equal 1, statements.size

      statements.clear
      @run.update_columns(budget_cents: nil)
      free = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))
      ActiveSupport::Notifications.subscribe("sql.active_record", &record)
      begin
        start(free, probe_config)
      ensure
        ActiveSupport::Notifications.unsubscribe(record)
      end
      assert_empty statements
    end

    test "the block's cost is not looked up when neither the step nor the run has a cap" do
      register_probe(cost_cents: 10)
      queries = []
      record = ->(*, payload) { queries << payload[:sql].to_s if payload[:sql].to_s.include?('"module_definitions"') }
      run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))

      ActiveSupport::Notifications.subscribed(record, "sql.active_record") do
        start(run, probe_config.merge("block" => "acme/invoice@1"))
      end

      assert_empty queries
    end

    def define_block(cost_cents)
      manifest = { "kind" => "block", "namespace" => "acme", "slug" => "invoice", "version" => 1, "label" => "Invoice",
                   "executor" => "action", "ports" => { "in" => {}, "out" => {} }, "cost_cents" => cost_cents,
                   "uses" => { "transport" => "rest", "connection" => "billing", "operation" => "create_invoice" } }
      create(:module_definition, scope: @project, kind: "block", namespace: "acme", slug: "invoice", manifest: manifest)
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

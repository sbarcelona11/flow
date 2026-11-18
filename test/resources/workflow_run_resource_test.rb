# frozen_string_literal: true

require "test_helper"

class WorkflowRunResourceTest < ActiveSupport::TestCase
  setup do
    @workflow = create(:workflow, :with_project_scope)
    @project = @workflow.scope
    @run = create(:workflow_run, workflow: @workflow, project: @project)
    @owner = @run.user
    @session = create(:terminal_session, :agent_session, user: @owner, project: @project, state: "ready")
    create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow), terminal_session: @session)
  end

  test "a ready step hands its owner the writable terminal socket and a colleague the read-only one" do
    @owner.update!(share_active_sessions: true)
    colleague = create(:user, :employee, company: @owner.companies.first)

    own = WorkflowRunResource.new(@run.reload, params: { viewer: @owner }).to_h["stepRuns"].first
    shared = WorkflowRunResource.new(@run.reload, params: { viewer: colleague }).to_h["stepRuns"].first

    assert own["websocketUrl"].start_with?("#{Settings.traefik.ws_base}/t/#{@session.route_token}/tty/ws")
    assert shared["websocketUrl"].start_with?("#{Settings.traefik.ws_base}/t/#{@session.route_token}/view/ws")
    assert own["uploadUrl"].start_with?("#{Settings.traefik.http_base}/t/#{@session.route_token}/upload")
    assert_nil shared["uploadUrl"]
  end

  test "a colleague gets no terminal socket for a step whose owner does not share it" do
    @owner.update!(share_active_sessions: false)
    colleague = create(:user, :employee, company: @owner.companies.first)

    step = WorkflowRunResource.new(@run.reload, params: { viewer: colleague }).to_h["stepRuns"].first
    own = WorkflowRunResource.new(@run.reload, params: { viewer: @owner }).to_h["stepRuns"].first

    assert_nil step["websocketUrl"]
    assert step["liveViewPrivate"]
    assert_equal false, own["liveViewPrivate"] # rubocop:disable Minitest/RefuteFalse
  end

  test "a step whose container is not up yet has no terminal socket" do
    @session.update!(state: "running")
    @owner.update!(share_active_sessions: false)
    colleague = create(:user, :employee, company: @owner.companies.first)

    step = WorkflowRunResource.new(@run.reload, params: { viewer: @owner }).to_h["stepRuns"].first
    unshared = WorkflowRunResource.new(@run.reload, params: { viewer: colleague }).to_h["stepRuns"].first

    assert_nil step["websocketUrl"]
    assert_equal false, unshared["liveViewPrivate"] # rubocop:disable Minitest/RefuteFalse
  end

  test "a chat-started run names where its request came from; any other run, nothing" do
    @run.update!(shared_context: { "chat" => {
      "provider" => "teams", "conversation" => { "id" => "19:a", "name" => "Onboarding", "team" => { "name" => "Sales" } },
      "actor" => { "name" => "Olo Brockhouse" }, "url" => "https://teams.microsoft.com/l/message/19:a/1"
    } })

    assert_equal({ "provider" => "Microsoft Teams", "conversation" => "Sales / Onboarding", "sender" => "Olo Brockhouse",
                   "url" => "https://teams.microsoft.com/l/message/19:a/1" }, WorkflowRunResource.new(@run).to_h["chatOrigin"])

    @run.update!(shared_context: {})
    assert_nil WorkflowRunResource.new(@run).to_h["chatOrigin"]
  end

  test "the run page heads a run waiting for a session slot as queued, and a working one as running" do
    @run.update_columns(state: "running")

    assert_equal "running", WorkflowRunResource.new(@run.reload).to_h["state"]

    @session.update_columns(state: "queued")

    assert_equal "queued", WorkflowRunResource.new(@run.reload).to_h["state"]
  end

  # == the "Runs on" badge (DESIGN.md §11) ==

  test "the badge names a runner of the run's company" do
    runner = create(:runner, company: @project.company, name: "Prod VPC")
    @run.update!(runner: runner)

    assert_equal "Prod VPC", WorkflowRunResource.new(@run.reload).to_h.dig("runner", "name")
  end

  test "a stale runner id naming another company's runner serializes none of that runner" do
    foreign = create(:runner, name: "Their VPC")
    @run.update_column(:runner_id, foreign.id)

    resource = WorkflowRunResource.new(@run.reload, params: { viewer: @owner }).to_h

    assert_equal foreign.id, resource["runnerId"]
    assert_nil resource["runner"]
    assert_not_includes resource.to_json, "Their VPC"
  end

  test "lists the sent actions a retry would send again, and not reads or failed calls" do
    server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing",
                                                     snapshot_tools: [ { "name" => "create_invoice" },
                                                                       { "name" => "list_invoices", "annotations" => { "readOnlyHint" => true } } ])
    sent = ->(effect, outcome, name, tool = "create_invoice") do
      step = create(:step, workflow: @workflow, name: name, kind: "action", kind_config: {
        "target" => "mcp_tool", "mcp_server_id" => server.id, "tool" => tool, "effect" => effect
      })
      step_run = create(:step_run, workflow_run: @run, step: step)
      call = ActionCall.create!(step_run: step_run, target_type: "mcp_tool", mcp_server: server, tool_name: tool,
                                effect: effect, arguments: {}, attempted_at: Time.current)
      call.finish!(outcome: outcome) if outcome
      step_run
    end
    with_feature(:workflow_action_steps, true, company: @project.company) do
      @invoice = sent.call("write", "succeeded", "Invoice")
      sent.call("read", "succeeded", "Look up", "list_invoices")
      sent.call("write", "failed", "Failed write")
      @unfinished = sent.call("send", nil, "Notify")
    end

    listed = WorkflowRunResource.new(@run.reload).to_h["resendableActions"]

    assert_equal [ { "stepRunId" => @invoice.id, "stepId" => @invoice.step_id, "stepName" => "Invoice",
                     "targetLabel" => "Billing · create_invoice", "effect" => "write", "outcome" => "succeeded" },
                   { "stepRunId" => @unfinished.id, "stepId" => @unfinished.step_id, "stepName" => "Notify",
                     "targetLabel" => "Billing · create_invoice", "effect" => "send", "outcome" => nil } ], listed
  end

  test "labels a resendable REST call by its connector, method and path" do
    operation = create(:api_operation, api_connector: create(:api_connector, scope: @project, name: "Payments"),
                                       http_method: "POST", path: "/charges", effect: "write")
    step = with_feature(:workflow_action_steps, true, company: @project.company) do
      create(:step, workflow: @workflow, kind: "action",
                    kind_config: { "target" => "rest_operation", "api_operation_id" => operation.id, "effect" => "write" })
    end
    step_run = create(:step_run, workflow_run: @run, step: step)
    ActionCall.create!(step_run: step_run, target_type: "rest_operation", api_operation: operation, tool_name: operation.name,
                       effect: "write", arguments: {}, attempted_at: Time.current).finish!(outcome: "unknown")

    listed = WorkflowRunResource.new(@run.reload).to_h["resendableActions"]

    assert_equal [ "Payments · POST /charges" ], listed.pluck("targetLabel")
  end

  test "a capped run reports its cap and live spend, and each step run its share, from one ledger read" do
    @run.update!(budget_cents: 500)
    step = @run.step_runs.first.step
    @run.step_runs.first.update!(budget_cents: 100)
    UsageStatistic.create!(terminal_session: @session, cost_cents: 42)

    queries = capture_ledger_queries { @json = WorkflowRunResource.new(@run.reload).to_h }

    assert_equal [ 500, 42 ], @json.values_at("budgetCents", "budgetSpentCents")
    assert_equal [ 100, 42 ], @json["stepRuns"].first.values_at("budgetCents", "budgetSpentCents")
    assert_equal step.id, @json["stepRuns"].first["stepId"]
    assert_equal 2, queries, "one grouped read for the steps and one for the run total"
  end

  test "a caller's computed spend is used without asking the ledger again" do
    @run.update!(budget_cents: 500)

    queries = capture_ledger_queries do
      @json = WorkflowRunResource.new(@run.reload, params: { budget_spend: { 0 => 1 }, budget_run_spent: 77 }).to_h
    end

    assert_equal 77, @json["budgetSpentCents"]
    assert_equal 0, queries
  end

  test "a run with no caps has no budget fields and reads no spend" do
    queries = capture_ledger_queries { @json = WorkflowRunResource.new(@run.reload).to_h }

    assert_equal [ nil, nil ], @json.values_at("budgetCents", "budgetSpentCents")
    assert_equal [ nil, nil, nil ], @json["stepRuns"].first.values_at("budgetCents", "budgetSpentCents", "budgetStop")
    assert_equal 0, queries
  end

  private

  def capture_ledger_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].include?("usage_statistics") && payload[:sql].include?("action_calls") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end

# frozen_string_literal: true

require "test_helper"

class Budgets::EnforcerTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, :admin, company: @company)
    @project = create(:project, company: @company, owner: @user)
    @workflow = create(:workflow, scope: @project)
    @step = create(:step, workflow: @workflow, position: 1)
    @other_step = create(:step, workflow: @workflow, position: 2)
    @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
    Rails.logger.stubs(:info)
  end

  test "stops a session at its step cap, with the message and the marker in one update" do
    session = live_session(@step, cap: 100, spent: 102)

    assert_equal :stopped, Budgets::Enforcer.enforce(session)

    session.reload
    assert_equal "failed", session.state
    assert_equal "Budget exceeded: this step spent $1.02 of its $1.00 cap.", session.error_message
    marker = session.metadata.fetch(TerminalSession::BUDGET_STOP_KEY)
    assert_equal [ "step", 100, 102 ], marker.values_at("scope", "cap_cents", "spent_cents")
    assert_not_nil marker["at"]
  end

  test "writes the message and the marker in a single update" do
    session = live_session(@step, cap: 100, spent: 100)

    assert_queries_match(/UPDATE "terminal_sessions" SET .*"error_message".*"metadata"/, count: 1) do
      Budgets::Enforcer.enforce(session)
    end
  end

  test "leaves a session below its cap alone" do
    session = live_session(@step, cap: 100, spent: 99)

    assert_equal :within, Budgets::Enforcer.enforce(session)

    assert_equal "ready", session.reload.state
    assert_nil session.error_message
    refute session.metadata.key?(TerminalSession::BUDGET_STOP_KEY)
  end

  test "a session that finished meanwhile is taken over, and keeps its outcome" do
    session = live_session(@step, cap: 100, spent: 150)
    TerminalSession.find(session.id).update_columns(state: "finished", finished_at: Time.current)

    assert_equal :taken_over, Budgets::Enforcer.enforce(session)

    assert_equal "finished", session.reload.state
    assert_nil session.error_message
  end

  test "a session that ended before the enforcer read it has nothing to enforce" do
    session = live_session(@step, cap: 100, spent: 150)
    session.update_columns(state: "failed")

    assert_equal :no_cap, Budgets::Enforcer.enforce(session)
    refute session.reload.metadata.key?(TerminalSession::BUDGET_STOP_KEY)
  end

  test "stopping twice changes nothing the second time" do
    session = live_session(@step, cap: 100, spent: 150)
    stale = TerminalSession.find(session.id)
    assert_equal :stopped, Budgets::Enforcer.enforce(session)
    stored = session.reload.metadata

    assert_equal :no_cap, Budgets::Enforcer.enforce(TerminalSession.find(session.id))
    assert_equal :taken_over, Budgets::Enforcer.enforce(stale)
    assert_equal stored, session.reload.metadata
  end

  test "a session without a cap runs no budget query" do
    session = live_session(@step, cap: nil, spent: 5000)
    session = TerminalSession.includes(step_run: :workflow_run).find(session.id)

    assert_queries_count(0) { assert_equal :no_cap, Budgets::Enforcer.enforce(session) }
  end

  test "a session that is not a workflow step has no cap" do
    session = create(:terminal_session, :agent_session, project: @project, user: @user, state: "ready")

    assert_equal :no_cap, Budgets::Enforcer.enforce(session)
  end

  test "the run cap ends every live session of the run and sets the failure reason" do
    @run.update!(budget_cents: 150)
    first = live_session(@step, spent: 100)
    second = live_session(@other_step, spent: 60)
    finished = live_session(@other_step, spent: 0)
    finished.update_columns(state: "finished")
    other_run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
    bystander = live_session(@step, spent: 500, run: other_run)

    assert_equal :stopped, Budgets::Enforcer.enforce(first)

    [ first, second ].each do |session|
      session.reload
      assert_equal "failed", session.state
      assert_equal "Budget exceeded: this run spent $1.60 of its $1.50 cap.", session.error_message
      assert_equal "run", session.metadata.dig(TerminalSession::BUDGET_STOP_KEY, "scope")
    end
    assert_equal "finished", finished.reload.state
    assert_equal "ready", bystander.reload.state
    assert_equal "budget_exceeded", @run.reload.failure_reason
  end

  test "the run cap also ends queued and not started sessions of the run" do
    @run.update!(budget_cents: 150)
    spender = live_session(@step, spent: 200)
    queued = live_session(@other_step, spent: 0)
    queued.update_columns(state: "queued", container_id: nil)
    waiting = live_session(@other_step, spent: 0)
    waiting.update_columns(state: "not_started", container_id: nil)

    assert_equal :stopped, Budgets::Enforcer.enforce(spender)

    assert_equal %w[failed failed failed], [ spender, queued, waiting ].map { |s| s.reload.state }
    assert_equal "run", queued.metadata.dig(TerminalSession::BUDGET_STOP_KEY, "scope")
  end

  test "a failure on one session of the run does not leave the others live" do
    @run.update!(budget_cents: 150)
    first = live_session(@step, spent: 100)
    broken = live_session(@other_step, spent: 60)
    last = live_session(@other_step, spent: 0)
    SessionService.expects(:fail_session_if).with { |args| args[:session].id == first.id }.returns(true)
    SessionService.expects(:fail_session_if).with { |args| args[:session].id == broken.id }.raises(ActiveRecord::LockWaitTimeout)
    SessionService.expects(:fail_session_if).with { |args| args[:session].id == last.id }.returns(true)

    assert_equal :stopped, Budgets::Enforcer.enforce(first)

    assert_equal "budget_exceeded", @run.reload.failure_reason
  end

  test "the run cap keeps a failure reason that is already set" do
    @run.update!(budget_cents: 50, failure_reason: "quota_exceeded")

    Budgets::Enforcer.enforce(live_session(@step, spent: 80))

    assert_equal "quota_exceeded", @run.reload.failure_reason
  end

  test "a run cap that is not reached leaves the run alone" do
    @run.update!(budget_cents: 500)
    session = live_session(@step, spent: 80)

    assert_equal :within, Budgets::Enforcer.enforce(session)
    assert_nil @run.reload.failure_reason
  end

  test "an admitted-but-unreleased session is stopped with the marker too" do
    with_scope_defaults(project: 1)
    session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step")
    SessionAdmissionService.enqueue!(session)
    SessionAdmissionService.drain!
    session.session_admission.reload.update!(launch_state: "claimed", claimed_at: Time.current)
    session.update_columns(state: "ready", container_id: "ctr-1")
    create(:step_run, workflow_run: @run, step: @step, terminal_session: session).update_columns(budget_cents: 100)
    UsageStatistic.create!(terminal_session: session, cost_cents: 100)
    TemporalService.stubs(:cancel_workflow)

    assert_equal :stopped, Budgets::Enforcer.enforce(TerminalSession.find(session.id))

    assert_equal "failed", session.reload.state
    assert_equal "step", session.metadata.dig(TerminalSession::BUDGET_STOP_KEY, "scope")
  end

  private

  def live_session(step, cap: nil, spent: 0, run: @run)
    session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step",
                                        state: "ready", container_id: "ctr-1", started_at: 1.hour.ago)
    UsageStatistic.create!(terminal_session: session, cost_cents: spent)
    create(:step_run, workflow_run: run, step: step, terminal_session: session).update_columns(budget_cents: cap)
    session
  end
end

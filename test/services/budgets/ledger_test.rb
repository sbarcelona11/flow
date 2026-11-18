# frozen_string_literal: true

require "test_helper"

class Budgets::LedgerTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, :admin, company: @company)
    @project = create(:project, company: @company, owner: @user)
    @workflow = create(:workflow, scope: @project)
    @step = create(:step, workflow: @workflow, position: 1)
    @other_step = create(:step, workflow: @workflow, position: 2)
    @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
  end

  test "the step spend sums every attempt of the step and nothing else" do
    first = attempt(@step, spent: 40)
    attempt(@step, spent: 30)
    attempt(@other_step, spent: 900)

    assert_equal 70, Budgets::Ledger.new(first).step_spent_cents
  end

  test "a session shared by two steps counts in full toward each step" do
    first = attempt(@step, spent: 40)
    second = create(:step_run, workflow_run: @run, step: @other_step, terminal_session: first.terminal_session)

    assert_equal 40, Budgets::Ledger.new(first).step_spent_cents
    assert_equal 40, Budgets::Ledger.new(second).step_spent_cents
  end

  test "the run spend sums every step" do
    first = attempt(@step, spent: 40)
    attempt(@other_step, spent: 900)

    assert_equal 940, Budgets::Ledger.new(first).run_spent_cents
  end

  test "a session shared by several step runs is counted once in the run total" do
    first = attempt(@step, spent: 40)
    create(:step_run, workflow_run: @run, step: @other_step, terminal_session: first.terminal_session)

    assert_equal 40, Budgets::Ledger.new(first).run_spent_cents
  end

  test "action call estimates count toward the step and the run" do
    first = attempt(@step, spent: 40)
    estimate(first, 25)
    estimate(attempt(@other_step, spent: 0), 10)

    ledger = Budgets::Ledger.new(first)
    assert_equal 65, ledger.step_spent_cents
    assert_equal 75, ledger.run_spent_cents
  end

  test "a running session stops at the cap, not below it" do
    @step.update!(budget_cents: 100)

    assert_nil verdict_for(spent: 99)

    at_cap = verdict_for(spent: 100)
    assert_equal :step, at_cap.scope
    assert_equal [ 100, 100 ], [ at_cap.cap_cents, at_cap.spent_cents ]
    assert_equal 101, verdict_for(spent: 101).spent_cents
  end

  test "a missing estimate counts as zero" do
    @step.update!(budget_cents: 100)

    assert_nil verdict_for(spent: 99, estimate_cents: nil, starting: true)
    assert verdict_for(spent: 100, estimate_cents: nil, starting: true)
  end

  test "an estimate is ignored for a running session" do
    @step.update!(budget_cents: 100)

    assert_nil verdict_for(spent: 90, estimate_cents: 50)
  end

  test "a start is refused when the spend plus the estimate would pass the cap" do
    @step.update!(budget_cents: 100)

    assert_nil verdict_for(spent: 75, estimate_cents: 25, starting: true)
    refused = verdict_for(spent: 75, estimate_cents: 26, starting: true)
    assert_equal [ :step, 100, 75, 26 ], refused.to_h.values_at(:scope, :cap_cents, :spent_cents, :estimate_cents)
  end

  test "a start with no estimate is refused only at the cap" do
    @step.update!(budget_cents: 100)

    assert_nil verdict_for(spent: 99, starting: true)
    assert verdict_for(spent: 100, starting: true)
  end

  test "the run cap is checked after the step cap" do
    @step.update!(budget_cents: 100)
    @run.update!(budget_cents: 150)
    step_run = attempt(@step, spent: 100)
    attempt(@other_step, spent: 60)

    assert_equal :step, Budgets::Ledger.new(step_run).verdict.scope

    @step.update!(budget_cents: nil)
    uncapped_step_run = attempt(@step, spent: 0)
    run_verdict = Budgets::Ledger.new(uncapped_step_run).verdict
    assert_equal [ :run, 150, 160 ], [ run_verdict.scope, run_verdict.cap_cents, run_verdict.spent_cents ]
  end

  test "no query runs when neither the step nor the run has a cap" do
    step_run = attempt(@step, spent: 500).reload
    step_run.workflow_run
    ledger = Budgets::Ledger.new(step_run)

    assert_queries_count(0) do
      assert_nil ledger.verdict
      assert_nil ledger.verdict(estimate_cents: 50, starting: true)
    end
  end

  test "a scope costs one query, and only when it has a cap" do
    @step.update!(budget_cents: 100)
    step_run = attempt(@step, spent: 10)
    step_run.workflow_run

    assert_queries_count(1) { Budgets::Ledger.new(step_run).verdict }
  end

  test "spend_by_step groups the run in one query" do
    first = attempt(@step, spent: 40)
    attempt(@step, spent: 30)
    attempt(@other_step, spent: 5)
    estimate(first, 20)
    third = create(:step, workflow: @workflow, position: 3)
    estimate(create(:step_run, workflow_run: @run, step: third), 7)

    result = assert_queries_count(1) { Budgets::Ledger.spend_by_step(@run) }

    assert_equal({ @step.id => 90, @other_step.id => 5, third.id => 7 }, result)
  end

  test "spend_by_step counts a session once per step" do
    first = attempt(@step, spent: 40)
    create(:step_run, workflow_run: @run, step: @step, terminal_session: first.terminal_session)

    assert_equal({ @step.id => 40 }, Budgets::Ledger.spend_by_step(@run))
  end

  private

  def attempt(step, spent:)
    session = create(:terminal_session, :agent_session, project: @project, user: @user)
    UsageStatistic.create!(terminal_session: session, cost_cents: spent)
    create(:step_run, workflow_run: @run, step: step, terminal_session: session)
  end

  def estimate(step_run, cents)
    ActionCall.create!(step_run: step_run, target_type: "mcp_tool", effect: "read",
                       attempted_at: Time.current, estimated_cost_cents: cents)
  end

  # Each call spends on a step of its own, so earlier calls do not add up.
  def verdict_for(spent:, estimate_cents: 0, starting: false)
    step = create(:step, workflow: @workflow, position: 100 + Step.count, budget_cents: @step.budget_cents)
    step_run = attempt(step, spent: spent)
    Budgets::Ledger.new(step_run).verdict(estimate_cents: estimate_cents, starting: starting)
  end
end

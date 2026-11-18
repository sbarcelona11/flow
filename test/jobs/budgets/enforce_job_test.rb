# frozen_string_literal: true

require "test_helper"

class Budgets::EnforceJobTest < ActiveJob::TestCase
  setup do
    company = create(:company)
    @user = create(:user, :admin, company: company)
    @project = create(:project, company: company, owner: @user)
    @workflow = create(:workflow, scope: @project)
    @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
    Rails.logger.stubs(:info)
  end

  test "ends a session that reached its cap" do
    session = capped_session(cap: 100, spent: 120)

    Budgets::EnforceJob.perform_now(session.id)

    assert_equal "failed", session.reload.state
  end

  test "leaves a session within its cap" do
    session = capped_session(cap: 100, spent: 20)

    Budgets::EnforceJob.perform_now(session.id)

    assert_equal "ready", session.reload.state
  end

  test "one job per run is in flight, and a lock error is retried" do
    assert_equal 1, Budgets::EnforceJob.concurrency_limit
    assert_equal :discard, Budgets::EnforceJob.concurrency_on_conflict
    assert_equal "Budgets::EnforceJob/budget-enforce-7", Budgets::EnforceJob.new(1, 7).concurrency_key
    assert Budgets::EnforceJob.rescue_handlers.any? { |klass, _| klass == "ActiveRecord::LockWaitTimeout" }
  end

  test "ignores a session that no longer exists" do
    assert_nothing_raised { Budgets::EnforceJob.perform_now(0) }
  end

  private

  def capped_session(cap:, spent:)
    session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step",
                                        state: "ready", container_id: "ctr-1", started_at: 1.hour.ago)
    UsageStatistic.create!(terminal_session: session, cost_cents: spent)
    create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow), terminal_session: session).update_columns(budget_cents: cap)
    session
  end
end

# frozen_string_literal: true

require "test_helper"

module Sessions
  class MonitorTest < ActiveSupport::TestCase
    setup do
      company = create(:company)
      @user = create(:user, :admin, company: company)
      @project = create(:project, company: company, owner: @user)
      @workflow = create(:workflow, scope: @project)
      @step = create(:step, workflow: @workflow, position: 1)
      @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
      @runtime = stub_container_runtime
      Rails.logger.stubs(:info)
      Rails.logger.stubs(:warn)
    end

    teardown { cleanup_runtime_overrides }

    test "the budget cap is checked before the quota error" do
      assert_equal Checks::BudgetCap, Monitor::CHECKS.first
      assert_equal Checks::QuotaError, Monitor::CHECKS.second
    end

    test "a session over its cap is stopped by the budget check, and no later check runs" do
      session = capped_session(cap: 100, spent: 100, error_message: "429 insufficient_quota")

      results = Monitor.new.visit(session)

      assert_equal [ :failed ], results.map(&:outcome)
      assert_equal "failed", session.reload.state
      assert_match(/Budget exceeded/, session.error_message)
    end

    test "a pass counts the stopped session as cleaned" do
      capped_session(cap: 100, spent: 100)

      assert_equal 1, Monitor.new.pass[:cleaned]
    end

    test "a pass over capped sessions loads each step run and run once, not once per session" do
      3.times { capped_session(cap: 100, spent: 1) }

      sessions = Monitor.candidates.to_a
      assert_no_queries do
        sessions.each { |session| Checks::BudgetCap.applies_to?(session) }
      end
    end

    private

    def capped_session(cap:, spent:, error_message: nil)
      session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step",
                                          state: "ready", container_id: "ctr-1", started_at: 1.hour.ago,
                                          error_message: error_message)
      UsageStatistic.create!(terminal_session: session, cost_cents: spent)
      create(:step_run, workflow_run: @run, step: @step, terminal_session: session).update_columns(budget_cents: cap)
      session
    end
  end
end

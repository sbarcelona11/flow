# frozen_string_literal: true

require "test_helper"

module Sessions
  module Checks
    class BudgetCapTest < ActiveSupport::TestCase
      setup do
        company = create(:company)
@user = create(:user, :admin, company: company)
        @project = create(:project, company: company, owner: @user)
        @workflow = create(:workflow, scope: @project)
        @step = create(:step, workflow: @workflow, position: 1)
        @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
        Rails.logger.stubs(:info)
      end

      test "applies to a live capped workflow step, however young, and reads no part of the terminal" do
        session = session_with(cap: 100, started_at: 5.seconds.ago)

        assert BudgetCap.applies_to?(session)
        assert_empty BudgetCap.parts
      end

      test "applies when only the run has a cap" do
        @run.update!(budget_cents: 100)

        assert BudgetCap.applies_to?(session_with(cap: nil))
      end

      test "does not apply without a cap, without a container, once ended or off a workflow step" do
        refute BudgetCap.applies_to?(session_with(cap: nil))
        refute BudgetCap.applies_to?(session_with(cap: 100, container_id: nil))
        refute BudgetCap.applies_to?(session_with(cap: 100, state: "failed"))
        refute BudgetCap.applies_to?(create(:terminal_session, :agent_session, project: @project, user: @user,
                                                                               state: "ready", container_id: "ctr"))
      end

      test "stops a session at its cap" do
        session = session_with(cap: 100, spent: 100)

        result = BudgetCap.new(session, runtime: nil).call(Snapshot.new)

        assert_predicate result, :stop?
        assert_equal :failed, result.outcome
        assert_equal "failed", session.reload.state
      end

      test "continues when the session is within its cap" do
        session = session_with(cap: 100, spent: 10)

        result = BudgetCap.new(session, runtime: nil).call(Snapshot.new)

        refute_predicate result, :stop?
        assert_equal "ready", session.reload.state
      end

      test "stops as taken over when the session ended meanwhile" do
        session = session_with(cap: 100, spent: 100)
        TerminalSession.find(session.id).update_columns(state: "finished")

        result = BudgetCap.new(session, runtime: nil).call(Snapshot.new)

        assert_predicate result, :stop?
        assert_equal :taken_over, result.outcome
        assert_equal "finished", session.reload.state
      end

      private

      def session_with(cap:, spent: 0, state: "ready", container_id: "ctr-1", started_at: 1.hour.ago)
        session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step",
                                            state: state, container_id: container_id, started_at: started_at)
        UsageStatistic.create!(terminal_session: session, cost_cents: spent)
        create(:step_run, workflow_run: @run, step: @step, terminal_session: session).update_columns(budget_cents: cap)
        session
      end
    end
  end
end

# frozen_string_literal: true

module Budgets
  # What a step and its run have spent, and whether that reached a cap.
  #
  # Spend is the usage cost of the sessions of the step runs plus the estimates
  # their action calls recorded. A session shared by several step runs counts in
  # full toward each step that used it (conservative), and once in the run total.
  class Ledger
    def self.spend_by_step(workflow_run)
      sql = ApplicationRecord.sanitize_sql_array([ <<~SQL.squish, { run_id: workflow_run.id } ])
        WITH sessions AS (
          SELECT DISTINCT step_id, terminal_session_id FROM step_runs
          WHERE workflow_run_id = :run_id AND terminal_session_id IS NOT NULL),
        usage AS (
          SELECT sessions.step_id, SUM(usage_statistics.cost_cents) AS cents
          FROM sessions JOIN usage_statistics ON usage_statistics.terminal_session_id = sessions.terminal_session_id
          GROUP BY sessions.step_id),
        estimates AS (
          SELECT step_runs.step_id, SUM(action_calls.estimated_cost_cents) AS cents
          FROM action_calls JOIN step_runs ON step_runs.id = action_calls.step_run_id
          WHERE step_runs.workflow_run_id = :run_id GROUP BY step_runs.step_id)
        SELECT COALESCE(usage.step_id, estimates.step_id) AS step_id,
               (COALESCE(usage.cents, 0) + COALESCE(estimates.cents, 0))::bigint AS cents
        FROM usage FULL JOIN estimates ON estimates.step_id = usage.step_id
      SQL
      ApplicationRecord.connection.select_rows(sql).to_h { |step_id, cents| [ step_id.to_i, cents.to_i ] }
    end

    def initialize(step_run)
      @step_run = step_run
    end

    def step_spent_cents
      spent(step_id: @step_run.step_id)
    end

    def run_spent_cents
      spent
    end

    # The step cap is checked before the run cap. A running session stops when
    # it has spent the cap; a start is also refused when the estimate would pass it.
    def verdict(estimate_cents: 0, starting: false)
      estimate_cents = estimate_cents.to_i
      exceeded = check(:step, @step_run.budget_cents, estimate_cents, starting) { step_spent_cents }
      exceeded || check(:run, @step_run.workflow_run.budget_cents, estimate_cents, starting) { run_spent_cents }
    end

    private

    def check(scope, cap, estimate, starting)
      return unless cap

      spent = yield
      return unless spent >= cap || (starting && estimate.positive? && spent + estimate > cap)

      Exceeded.new(scope: scope, cap_cents: cap, spent_cents: spent, estimate_cents: starting ? estimate : 0)
    end

    def spent(step_id: nil)
      runs = "SELECT id, terminal_session_id FROM step_runs WHERE workflow_run_id = :run_id" \
             "#{' AND step_id = :step_id' if step_id}"
      sql = ApplicationRecord.sanitize_sql_array([ <<~SQL.squish, { run_id: @step_run.workflow_run_id, step_id: step_id } ])
        SELECT
          (SELECT COALESCE(SUM(cost_cents), 0) FROM usage_statistics
            WHERE terminal_session_id IN (SELECT terminal_session_id FROM (#{runs}) usage_runs))
          + (SELECT COALESCE(SUM(estimated_cost_cents), 0) FROM action_calls
              WHERE step_run_id IN (SELECT id FROM (#{runs}) estimate_runs))
      SQL
      ApplicationRecord.connection.select_value(sql).to_i
    end
  end
end

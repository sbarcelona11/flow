# frozen_string_literal: true

module Budgets
  # The fast path behind usage telemetry: when a step session's usage may have reached a
  # cap, enqueue the enforcer instead of waiting for the monitor's next pass. It runs inside
  # UsageStatistics::Accumulator, so it reads at most one row, and nothing in it may fail the
  # ingestion of usage.
  module Watch
    # @param cost_cents [Integer, nil] the session's own total after this batch
    def self.recorded(terminal_session, cost_cents)
      return unless terminal_session.workflow_step?

      step_cap, run_cap = StepRun.where(terminal_session_id: terminal_session.id)
                                 .joins(:workflow_run).limit(1)
                                 .pick("step_runs.budget_cents", "workflow_runs.budget_cents")
      return unless run_cap || (step_cap && cost_cents.to_i >= step_cap)

      Budgets::EnforceJob.perform_later(terminal_session.id)
    rescue StandardError => e
      Rails.logger.warn("[Budgets::Watch] session=#{terminal_session.id} not checked: #{e.class}: #{e.message}")
    end
  end
end

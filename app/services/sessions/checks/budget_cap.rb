# frozen_string_literal: true

module Sessions
  module Checks
    # Ends a workflow step whose step or run has spent its cap (Budgets::Enforcer): the
    # backstop for the fast path in UsageStatistics::Accumulator. It reads no terminal, and
    # has no MIN_AGE, since spend is what it judges, not the container. The monitor
    # preloads step_run: :workflow_run, so a session without a cap costs no query.
    class BudgetCap < Base
      def self.applies_to?(session)
        return false unless session.workflow_step? && session.state.in?(ACTIVE_STATES) && session.container_id.present?

        step_run = session.step_run
        step_run.present? && (step_run.budget_cents.present? || step_run.workflow_run.budget_cents.present?)
      end

      def self.parts = [].freeze

      def call(_snapshot)
        case Budgets::Enforcer.enforce(session)
        when :stopped then stop(:failed)
        when :taken_over then stop(:taken_over)
        else continue
        end
      end
    end
  end
end

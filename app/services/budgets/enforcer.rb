# frozen_string_literal: true

module Budgets
  # Ends a live workflow-step session that has reached a spend cap. Two callers reach it:
  # the monitor's BudgetCap check on every pass, and EnforceJob, enqueued by Watch when
  # usage arrives. Either may run while the session ends on its own, or while the other
  # runs, so every stop is a compare-and-set under the session's row lock
  # (SessionService.fail_session_if): the guard re-reads the spend, and a session that
  # ended or was paused since is left alone. The failure and the budget_stop marker are one
  # update, so a session is never stopped twice and a finished step is never flipped.
  class Enforcer
    LIVE_STATES = Sessions::Checks::Base::ACTIVE_STATES
    UNENDED_STATES = (%w[not_started queued] + LIVE_STATES).freeze

    # @return [Symbol] :no_cap (nothing to enforce), :within, :stopped or :taken_over
    def self.enforce(session) = new(session).enforce

    def initialize(session)
      @session = session
    end

    def enforce
      step_run = capped_step_run
      return :no_cap unless step_run

      verdict = Ledger.new(step_run).verdict
      return :within unless verdict

      verdict.scope == :run ? stop_run(step_run, verdict) : stop_step(@session, step_run, verdict)
    end

    private

    # The step run of a live workflow-step session, when it or its run has a cap. The run is
    # read here so that an uncapped session costs no budget query.
    def capped_step_run
      return unless @session.workflow_step? && @session.state.in?(LIVE_STATES)

      step_run = @session.step_run
      return unless step_run && (step_run.budget_cents || step_run.workflow_run.budget_cents)

      step_run
    end

    def stop_step(session, step_run, verdict)
      stopped = fail_if(session, verdict, LIVE_STATES) { Ledger.new(step_run).step_spent_cents }
      log(session, verdict, stopped)
      stopped ? :stopped : :taken_over
    end

    # Every session of the run that has not ended, including those still waiting for a slot
    # or not started: they passed PrepareStepActivity before the cap was reached and would
    # otherwise launch and spend. One session failing to stop must not leave the rest live.
    def stop_run(step_run, verdict)
      run = step_run.workflow_run
      outcome = :taken_over
      unended_sessions(run).each do |session|
        stopped = fail_if(session, verdict, UNENDED_STATES) { Ledger.new(session.step_run).run_spent_cents }
        log(session, verdict, stopped)
        outcome = :stopped if stopped && session.id == @session.id
        mark_run(run) if stopped
      rescue StandardError => e
        Rails.logger.warn("[Budgets::Enforcer] session=#{session.id} not stopped: #{e.class}: #{e.message}")
      end
      outcome
    end

    # The block reads the spend under the lock; the message and the marker say that value.
    def fail_if(session, verdict, states)
      spent = nil
      reached = -> { verdict.with(spent_cents: spent) }
      SessionService.fail_session_if(
        session: session, expected_state: session.state,
        error_message: -> { reached.call.message(:running) },
        metadata: -> { { TerminalSession::BUDGET_STOP_KEY => reached.call.to_marker } }
      ) do |locked|
        spent = yield
        locked.state.in?(states) && spent >= verdict.cap_cents
      end
    end

    def unended_sessions(run)
      TerminalSession.where(state: UNENDED_STATES, id: run.step_runs.select(:terminal_session_id))
                     .includes(step_run: :workflow_run).to_a
    end

    # Atomic, and only when nothing else has already said why the run ended.
    def mark_run(run)
      WorkflowRun.where(id: run.id, failure_reason: nil).update_all(failure_reason: "budget_exceeded")
    end

    def log(session, verdict, stopped)
      Rails.logger.info("[Budgets::Enforcer] session=#{session.id} #{verdict.scope} cap=#{verdict.cap_cents} " \
                        "spent=#{verdict.spent_cents} #{stopped ? 'stopped' : 'left alone'}")
    end
  end
end

# frozen_string_literal: true

module Budgets
  # Ends a session that may have crossed its cap, sooner than the monitor's next pass.
  # The enforcer decides; a session that is gone, ended or within its cap is not an error.
  #
  # Watch enqueues on every telemetry batch once a cap is crossed, until the sessions are
  # stopped, so one job per run is in flight and the rest are dropped: the next batch,
  # about 2 s later, asks again.
  class EnforceJob < ApplicationJob
    queue_as :default

    limits_concurrency to: 1, key: ->(_session_id, run_id = nil) { "budget-enforce-#{run_id}" },
                       duration: 1.minute, on_conflict: :discard

    retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: 2.seconds, attempts: 3

    def perform(terminal_session_id, _run_id = nil)
      session = TerminalSession.find_by(id: terminal_session_id)
      return unless session

      result = Enforcer.enforce(session)
      Rails.logger.info("[Budgets::EnforceJob] session=#{session.id} #{result}")
    end
  end
end

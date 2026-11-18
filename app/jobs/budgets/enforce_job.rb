# frozen_string_literal: true

module Budgets
  # Ends a session that may have crossed its cap, sooner than the monitor's next pass.
  # The enforcer decides; a session that is gone, ended or within its cap is not an error.
  class EnforceJob < ApplicationJob
    queue_as :default

    def perform(terminal_session_id)
      session = TerminalSession.find_by(id: terminal_session_id)
      return unless session

      result = Enforcer.enforce(session)
      Rails.logger.info("[Budgets::EnforceJob] session=#{session.id} #{result}")
    end
  end
end

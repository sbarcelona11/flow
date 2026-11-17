# frozen_string_literal: true

module Connectors
  Context = Data.define(:project, :user, :step_run_id, :run_id, :tool_result_id) do
    def initialize(project:, user:, step_run_id:, run_id:, tool_result_id: nil) = super
  end
end

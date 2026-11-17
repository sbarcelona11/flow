# frozen_string_literal: true

module Activities
  module Workflow
    class ActionStatusActivity < ::Activities::Base
      def execute(input)
        handle = { "tool_result_id" => input["tool_result_id"] }
        ::Actions::Pipeline.status(step_run: ToolResult.find(handle["tool_result_id"]).step_run, handle: handle)
      end
    end
  end
end

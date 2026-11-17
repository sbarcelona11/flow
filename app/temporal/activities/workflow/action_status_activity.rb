# frozen_string_literal: true

module Activities
  module Workflow
    class ActionStatusActivity < ::Activities::Base
      def execute(input)
        { "state" => ToolResult.find(input["tool_result_id"]).state }
      end
    end
  end
end

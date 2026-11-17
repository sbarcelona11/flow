# frozen_string_literal: true

module Activities
  module Workflow
    class ActionStatusActivity < ::Activities::Base
      def execute(input)
        ::Actions::Pipeline.status(handle: { "tool_result_id" => input["tool_result_id"] })
      end
    end
  end
end

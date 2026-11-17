# frozen_string_literal: true

module Api
  module V1
    module Projects
      class BlocksController < ApplicationController
        requires_feature :workflow_action_steps

        # @summary Module blocks this project can use in the builder, with their status
        def index
          render json: Modules::Registry.new(current_project).blocks.map { |entry| ModuleBlockResource.new(entry).to_h }
        end
      end
    end
  end
end

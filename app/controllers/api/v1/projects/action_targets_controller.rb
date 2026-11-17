# frozen_string_literal: true

module Api
  module V1
    module Projects
      class ActionTargetsController < ApplicationController
        requires_feature :workflow_action_steps

        # @summary Tools an action step of this project can call
        def index
          render json: Actions::Catalog.new(current_project).targets.map { |target| ActionTargetResource.new(target).to_h }
        end
      end
    end
  end
end

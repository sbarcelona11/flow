# frozen_string_literal: true

module Api
  module V1
    module Projects
      class BlocksController < ApplicationController
        requires_feature :workflow_action_steps

        # @summary Module blocks this project can use in the builder, with their status
        def index
          definitions = ModuleDefinition.for_project(current_project).where(kind: "block").index_by do |definition|
            "#{definition.namespace}/#{definition.slug}@#{definition.version}"
          end
          render json: Modules::Registry.new(current_project).blocks.map { |entry|
            ModuleBlockResource.new(entry, params: { definitions: definitions }).to_h
          }
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    module Projects
      class BlocksController < ApplicationController
        requires_feature :workflow_action_steps

        rescue_from Modules::Composite::Expander::Refused do |error|
          render json: { error: error.message }, status: :unprocessable_content
        end

        def index
          definitions = ModuleDefinition.for_project(current_project).where(kind: "block").index_by do |definition|
            "#{definition.namespace}/#{definition.slug}@#{definition.version}"
          end
          render json: Modules::Registry.new(current_project).blocks.map { |entry|
            ModuleBlockResource.new(entry, params: { definitions: definitions }).to_h
          }
        end

        # A composite block as ordinary draft steps; nothing is saved. With `workflow_id`, the steps are also checked as a
        # Save would check them.
        def expand
          workflow = current_project.workflows.active.find(params[:workflow_id]) if params[:workflow_id].present?
          result = Modules::Composite::Expander.new(
            project: current_project, ref: params.require(:ref), bindings: bindings, workflow: workflow,
            first_index: first_index, at: position
          ).call
          render json: { steps: result.steps, warnings: result.warnings, instance: result.instance, unbound: result.unbound }
        rescue Modules::Registry::Unknown
          raise ActiveRecord::RecordNotFound
        end

        private

        def bindings
          raw = params[:bindings]
          raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
        end

        def first_index = params.fetch(:first_index, 1).to_i.clamp(1, 100_000)

        def position
          raw = params[:at]
          raw.respond_to?(:permit) ? raw.permit(:x, :y).to_h : {}
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    module Projects
      class ActionTargetsPolicy < Api::V1::ApplicationPolicy
        def index? = project_accessible?
      end
    end
  end
end

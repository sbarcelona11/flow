# frozen_string_literal: true

module Web
  module Company
    module Projects
      class AutomationsPolicy < Web::Company::ApplicationPolicy
        def index? = project_accessible?
      end
    end
  end
end

# frozen_string_literal: true

module Web
  module Company
    module Projects
      class ApiServiceSetupsPolicy < Web::Company::ApplicationPolicy
        def create? = project_writable?
      end
    end
  end
end

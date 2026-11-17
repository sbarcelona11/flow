# frozen_string_literal: true

module Web
  module Company
    module Projects
      class ApiConnectorImportsPolicy < Web::Company::ApplicationPolicy
        def preview? = project_writable?
        def create? = project_writable?
      end
    end
  end
end

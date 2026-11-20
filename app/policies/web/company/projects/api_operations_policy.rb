# frozen_string_literal: true

module Web
  module Company
    module Projects
      class ApiOperationsPolicy < Web::Company::ApplicationPolicy
        def create? = project_writable?
        def update? = project_writable?
        def destroy? = project_writable?
        def test_call? = project_writable?
      end
    end
  end
end

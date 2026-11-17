# frozen_string_literal: true

module Web
  module Company
    module Projects
      class ApiConnectorsPolicy < Web::Company::ApplicationPolicy
        def index? = project_accessible?
        def show? = project_accessible?
        def new? = project_writable?
        def create? = project_writable?
        def edit? = project_writable?
        def update? = project_writable?
        def archive? = project_writable?
        def unarchive? = project_writable?
      end
    end
  end
end

# frozen_string_literal: true

module Web
  module Company
    module Projects
      class ModuleDefinitionsPolicy < Web::Company::ApplicationPolicy
        def index? = project_accessible?
        def show? = project_accessible?
        def create? = project_writable?
        def new_version? = project_writable?
        def from_steps? = project_writable?
        def enable? = project_writable?
        def disable? = project_writable?
        def archive? = project_writable?
        def approve? = review_policy.approve?
        def reject? = review_policy.reject?

        private

        def review_policy = AuthoringReviewPolicy.new(context, :authoring_review)
      end
    end
  end
end

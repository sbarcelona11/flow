# frozen_string_literal: true


module Web
  module Company
    module Projects
      class AuthoringReviewPolicy < Web::Company::ApplicationPolicy
        def approve? = reviewer?
        def reject? = reviewer?

        private

        def reviewer?
          current_user.is_a?(User) && project_writable?
        end
      end
    end
  end
end

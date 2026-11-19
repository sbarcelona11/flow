# frozen_string_literal: true

module Web
  module Company
    module Projects
      # Approving or rejecting authored work needs the signed-in web session of a project writer.
      # Tools (Builder, personal MCP) act as a User but never hold a live UserSession.
      class AuthoringReviewPolicy < Web::Company::ApplicationPolicy
        def approve? = reviewer?
        def reject? = reviewer?

        private

        def reviewer?
          web_session? && project_writable?
        end

        def web_session?
          session = context.respond_to?(:user_session) ? context.user_session : nil
          current_user.is_a?(User) && session.is_a?(UserSession) && session.user_id == current_user.id &&
            UserSession.live.exists?(session.id)
        end
      end
    end
  end
end

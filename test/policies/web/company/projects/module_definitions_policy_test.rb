# frozen_string_literal: true

require "test_helper"

module Web
  module Company
    module Projects
      class ModuleDefinitionsPolicyTest < ActiveSupport::TestCase
        setup do
          @company = create(:company)
          @owner = create(:user, company: @company)
          @project = create(:project, company: @company, owner: @owner)
          @viewer = create(:user, company: @company, membership_role: :viewer)
          @project.add_collaborator(@viewer)
        end

        def policy_for(user, session: :web)
          user_session = session == :web ? UserSession.start!(user: user) : session
          ModuleDefinitionsPolicy.new(ProjectContext.new(user, {}, project: @project, user_session: user_session), :module_definitions)
        end

        test "a project writer can do everything, a viewer only reads" do
          writer = policy_for(@owner)
          %i[index? show? create? new_version? enable? disable? archive? approve? reject?].each { |query| assert writer.public_send(query), query }

          reader = policy_for(@viewer)
          assert reader.index?
          assert reader.show?
          %i[create? new_version? enable? disable? archive? approve? reject?].each { |query| assert_not reader.public_send(query), query }
        end

        test "approve and reject need a web session, a token holder acting as the user is refused" do
          tool = policy_for(@owner, session: nil)

          assert tool.create?
          assert_not tool.approve?
          assert_not tool.reject?
        end
      end
    end
  end
end

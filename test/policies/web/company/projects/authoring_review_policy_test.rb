# frozen_string_literal: true

require "test_helper"

module Web
  module Company
    module Projects
      class AuthoringReviewPolicyTest < ActiveSupport::TestCase
        setup do
          @company = create(:company)
          @owner = create(:user, company: @company)
          @project = create(:project, company: @company, owner: @owner)
          @member = create(:user, company: @company)
          @project.add_collaborator(@member)
          @viewer = create(:user, company: @company, membership_role: :viewer)
          @project.add_collaborator(@viewer)
          @outsider = create(:user)
        end

        def policy_for(user, session: :web)
          user_session = session == :web ? (user && UserSession.start!(user: user)) : session
          AuthoringReviewPolicy.new(ProjectContext.new(user, {}, project: @project, user_session: user_session), :authoring_review)
        end

        test "a project writer in a web session can approve and reject" do
          [ @owner, @member ].each do |user|
            assert policy_for(user).approve?
            assert policy_for(user).reject?
          end
        end

        test "a viewer, an outsider and no one cannot" do
          [ @viewer, @outsider, nil ].each do |user|
            assert_not policy_for(user).approve?
            assert_not policy_for(user).reject?
          end
        end

        test "an impersonated session cannot approve or reject" do
          impersonated = UserSession.start!(user: @owner, impersonator: @member)
          policy = policy_for(@owner, session: impersonated)

          assert_not policy.approve?
          assert_not policy.reject?
        end

        test "a project writer without a web session cannot (tools act as a user with no session)" do
          assert_not policy_for(@owner, session: nil).approve?
          assert_not policy_for(@owner, session: nil).reject?
        end

        test "someone else's or a revoked session does not count" do
          other = UserSession.start!(user: @member)
          revoked = UserSession.start!(user: @owner).tap(&:revoke!)

          [ other, revoked ].each do |session|
            policy = AuthoringReviewPolicy.new(ProjectContext.new(@owner, {}, project: @project, user_session: session), :authoring_review)
            assert_not policy.approve?
            assert_not policy.reject?
          end
        end

        test "writes follow the connectors rule when there is a web session" do
          [ @owner, @member, @viewer, @outsider ].each do |user|
            connectors = ApiConnectorsPolicy.new(ProjectContext.new(user, {}, project: @project), :api_connectors)
            assert_equal connectors.update?, policy_for(user).approve?
            assert_equal connectors.update?, policy_for(user).reject?
          end
        end
      end
    end
  end
end

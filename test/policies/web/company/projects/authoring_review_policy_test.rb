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

        def policy_for(user)
          AuthoringReviewPolicy.new(ProjectContext.new(user, {}, project: @project), :authoring_review)
        end

        test "a project writer can approve and reject" do
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

        test "writes follow the connectors rule" do
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

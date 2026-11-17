# frozen_string_literal: true

require "test_helper"

module Web
  module Company
    module Projects
      class ApiConnectorsPolicyTest < ActiveSupport::TestCase
        ACTIONS = %i[index? show? create? update? archive?].freeze

        setup do
          @company = create(:company)
          @owner = create(:user, company: @company)
          @project = create(:project, company: @company, owner: @owner)
          @viewer = create(:user, company: @company, membership_role: :viewer)
          @project.add_collaborator(@viewer)
          @outsider = create(:user)
        end

        def policy_for(user)
          ApiConnectorsPolicy.new(ProjectContext.new(user, {}, project: @project), :api_connectors)
        end

        test "writes follow the MCP servers rule" do
          [ @owner, @viewer, @outsider ].each do |user|
            mcp = MCPServersPolicy.new(ProjectContext.new(user, {}, project: @project), :mcp_servers)
            policy = policy_for(user)

            assert_equal mcp.index?, policy.index?
            assert_equal mcp.index?, policy.show?
            %i[create? update?].each { |action| assert_equal mcp.public_send(action), policy.public_send(action) }
            assert_equal mcp.update?, policy.archive?
          end
        end

        test "a viewer reads but does not write" do
          policy = policy_for(@viewer)

          assert policy.index?
          assert policy.show?
          (ACTIONS - %i[index? show?]).each { |action| assert_not policy.public_send(action) }
        end
      end
    end
  end
end

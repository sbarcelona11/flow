# frozen_string_literal: true

require "test_helper"

# Policy (Web::Company::Projects::ModuleDefinitionsPolicy): index/show => project_accessible?;
# create, new_version, enable, disable, archive => project_writable?; approve/reject also need a live web session.
class Web::Company::Projects::ModuleDefinitionsAuthorizationTest < ActionDispatch::IntegrationTest
  include AuthorizationMatrix

  setup do
    setup_project_authz_personas
    @definition = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "reviewed")
  end

  teardown { teardown_authz }

  def flagged(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  def manifest(slug) = { "kind" => "type", "namespace" => "local", "slug" => slug, "version" => 1, "label" => "T", "schema" => { "type" => "string" } }.to_json

  test "index and show are project reads" do
    flagged do
      assert_project_read { get company_project_module_definitions_path(@project), as: :json }
      assert_project_read { get company_project_module_definition_path(@project, @definition), as: :json }
    end
  end

  test "create is a project write and a viewer cannot create" do
    flagged do
      assert_project_write(allowed: :created) do
        post company_project_module_definitions_path(@project), params: { manifest: manifest("t-#{SecureRandom.hex(3)}") }, as: :json
      end
    end
    assert_equal 3, ModuleDefinition.where("slug LIKE ?", "t-%").count, "only owner, admin and collaborator may create"
  end

  test "from_steps is a project write and a viewer cannot save a block" do
    workflow = create(:workflow, scope: @project)
    step = create(:step, workflow: workflow, position: 1, kind: "approval")
    with_feature(:automations_canvas, true, company: @company) do
      flagged do
        assert_project_write(allowed: :created) do |role|
          post from_steps_company_project_module_definitions_path(@project),
               params: { workflow_id: workflow.id, step_ids: [ step.id ], label: "Block #{role}" }, as: :json
        end
      end
    end
    assert_equal 3, ModuleDefinition.where("slug LIKE ?", "block-%").count, "only owner, admin and collaborator may save"
  end

  test "approve is a project write and a viewer cannot approve" do
    flagged do
      assert_project_write(allowed: :success) do |role|
        pending = create(:module_definition, :control_block, :proposed, scope: @project, namespace: "local", slug: "p-#{role.to_s.dasherize}")
        post approve_company_project_module_definition_path(@project, pending), params: { expected_digest: Authoring::Review.digest_for(pending) }, as: :json
        assert_not ModuleDefinition.find(pending.id).reviewed? if role == :viewer
      end
    end
  end

  test "the lifecycle actions are project writes" do
    flagged do
      %i[disable enable archive].each do |action|
        assert_project_write(allowed: :success) do
          post public_send(:"#{action}_company_project_module_definition_path", @project, create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "l-#{SecureRandom.hex(3)}")), as: :json
        end
      end
    end
  end
end

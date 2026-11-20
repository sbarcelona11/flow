# frozen_string_literal: true

require "test_helper"

module PersonalTools
  # The agent door refuses a credential value in the arguments of an action step it writes. A person's save is only warned
  # (DataFlow::Check), and a copy is never blocked.
  class CredentialDoorTest < ActiveSupport::TestCase
    KEY = "sk_live_#{'a1B2c3D4' * 3}"

    setup do
      build_authoring_world
      @connector = create(:api_connector, scope: @project, name: "billing")
      @operation = create(:api_operation, api_connector: @connector, name: "list_things")
      @workflow = create(:workflow, scope: @project, name: "Flow").tap { |workflow| Versions.ensure_baseline!(workflow) }
    end

    def config(arguments) = { target: "rest_operation", api_operation_id: @operation.id, effect: "read", output_name: "out.json", arguments: arguments }

    def create_step(arguments) = run_tool(CreateWorkflowStep, { workflow_id: @workflow.id, name: "Call", kind: "action", kind_config: config(arguments) })

    test "create_workflow_step refuses a credential value in action arguments and accepts ordinary ones" do
      assert_refused(create_step({ "q" => KEY }), /credential/)
      assert_refused(create_step({ "nested" => [ { "q" => "token=#{KEY}" } ] }), /credential/)
      assert_equal 0, @workflow.steps.count

      ordinary = { "q" => "Basic authentication", "page_token" => "CAESBkFhYmJjYxABGAEiAA", "id" => "{{context:invoice}}" }
      assert_equal 0, create_step(ordinary)[:exit_code]
    end

    test "update_workflow_step refuses it too" do
      step = create(:step, workflow: @workflow, name: "Call", position: 1, kind: "action", kind_config: config({}).stringify_keys.merge("target" => "rest_operation"))

      result = run_tool(UpdateWorkflowStep, { workflow_id: @workflow.id, step_id: step.id, kind_config: config({ "q" => KEY }) })

      assert_refused(result, /credential/)
      assert_equal({}, step.reload.kind_config["arguments"])
    end

    test "a web save is not blocked: the step model accepts the value, and a duplicate of such a workflow works" do
      step = create(:step, workflow: @workflow, name: "Call", position: 1, kind: "action",
                           kind_config: { "target" => "rest_operation", "api_operation_id" => @operation.id, "effect" => "read",
                                          "output_name" => "out.json", "arguments" => { "q" => "Basic authentication on #{KEY}" } })

      assert step.persisted?
      copy = WorkflowDuplicator.new(@workflow, target_scope: @project, name: "Copy").duplicate!
      assert_equal 1, copy.steps.not_deleted.count
    end
  end
end

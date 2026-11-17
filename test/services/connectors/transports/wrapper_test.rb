# frozen_string_literal: true

require "test_helper"

class Connectors::Transports::WrapperTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
    @tool = create(:tool, scope: @project, name: "invoice_lines", display_name: "Invoice lines",
                          description: "Computes lines", input_schema: { "type" => "object" })
    @transport = Connectors::Registry.fetch(:wrapper).new
  end

  test "is registered for the wrapper target and is asynchronous" do
    assert_equal Connectors::Transports::Wrapper, Connectors::Registry.for_target("wrapper")
    assert_predicate @transport, :async?
  end

  test "operations equal what the catalog built" do
    expected = [ Connectors::Operation.new(key: @tool.id.to_s, name: "Invoice lines", description: "Computes lines",
                                           input_schema: { "type" => "object" }, output_schema: nil, base_effect: "write",
                                           drifted: false) ]

    assert_equal expected, @transport.operations(@tool)
  end

  test "lists enabled project wrappers by name" do
    create(:tool, :disabled, scope: @project)
    create(:tool, scope: create(:project, :standalone))

    assert_equal [ @tool ], @transport.connections(@project).to_a
    assert_equal @tool, @transport.connection_for({ "tool_id" => @tool.id }, @project)
    assert_nil @transport.connection_for({ "tool_id" => create(:tool).id }, @project)
  end

  def gone
    Connectors::Operation.new(key: "gone", name: "gone", description: nil, input_schema: nil, output_schema: nil,
                              base_effect: nil, drifted: false)
  end

  test "labels match the action call labels" do
    operation = @transport.operations(@tool).first

    assert_nil @transport.owner(@tool)
    assert_equal "Invoice lines", @transport.label(@tool, operation)
    assert_equal "Invoice lines", @transport.target_name(@tool, operation)
    assert_equal "gone", @transport.label(nil, gone)
  end

  test "refuses a wrapper that takes a repository" do
    assert_equal "Wrappers that use a repository can't run as actions.",
                 @transport.action_blocker({ "properties" => { "repository_id" => {} } })
    assert_nil @transport.action_blocker({ "properties" => { "q" => {} } })
  end

  test "status reads the tool result state" do
    result = ToolResult.create!(tool: @tool, step_run: create(:step_run), execution_id: ToolResult.generate_id, state: "processing")

    assert_equal "processing", @transport.status({ "tool_result_id" => result.id })
  end

  test "call starts the container with the pipeline's tool result and records nothing itself" do
    step_run = create(:step_run)
    tool_result = ToolResult.create!(tool: @tool, step_run: step_run, execution_id: ToolResult.generate_id, state: "processing")
    context = Connectors::Context.new(project: @project, user: nil, step_run_id: step_run.id, run_id: step_run.workflow_run_id,
                                      tool_result_id: tool_result.id)
    mock_temporal_start

    result = assert_no_difference(-> { ToolResult.count }) do
      @transport.call(connection: @tool, operation: @transport.operations(@tool).first, arguments: {}, context: context)
    end

    assert_equal({ "tool_result_id" => tool_result.id, "deadline_seconds" => ContainerStrategies::ToolStrategy::DEFAULT_TIMEOUT + 120 },
                 result.structured)
    assert_equal "processing", tool_result.reload.state
  end

  test "refuses a wrapper given a repository reference" do
    assert_equal "Wrappers that use a repository can't run as actions.",
                 @transport.action_blocker({}, { ContainerStrategies::CustomToolStrategy::REPOSITORY_REFERENCE => 1 })
  end
end

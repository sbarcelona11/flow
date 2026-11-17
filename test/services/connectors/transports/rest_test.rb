# frozen_string_literal: true

require "test_helper"

class Connectors::Transports::RestTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
    @schema = { "type" => "object", "properties" => { "query" => { "type" => "object", "properties" => {} } } }
    @connector = create(:api_connector, scope: @project, name: "Payments")
    @refund = create(:api_operation, api_connector: @connector, name: "refund", http_method: "DELETE", path: "/charges",
                                     effect: "irreversible", description: "Refund a charge", input_schema: @schema)
    @transport = Connectors::Registry.fetch(:rest).new
  end

  test "is registered for the rest_operation target" do
    assert_equal Connectors::Transports::Rest, Connectors::Registry.for_target("rest_operation")
    assert_not @transport.async?
  end

  test "operations equal what the catalog built" do
    expected = [ Connectors::Operation.new(key: @refund.id.to_s, name: "refund", description: "Refund a charge",
                                           input_schema: @schema, output_schema: nil, base_effect: "irreversible", drifted: false) ]

    assert_equal expected, @transport.operations(@refund)
  end

  test "lists enabled operations of enabled project connectors, by connector then name" do
    create(:api_operation, api_connector: @connector, name: "disabled_one", enabled: false)
    create(:api_operation, api_connector: create(:api_connector, scope: @project, enabled: false))
    create(:api_operation, api_connector: create(:api_connector))
    other = create(:api_operation, api_connector: create(:api_connector, scope: @project, name: "Accounts"), name: "zeta")

    assert_equal [ other, @refund ], @transport.connections(@project).to_a
    assert_equal @refund, @transport.connection_for({ "api_operation_id" => @refund.id }, @project)
  end

  def gone
    Connectors::Operation.new(key: "gone", name: "gone", description: nil, input_schema: nil, output_schema: nil,
                              base_effect: nil, drifted: false)
  end

  test "labels match the action call labels" do
    operation = @transport.operations(@refund).first

    assert_equal "Payments", @transport.owner(@refund)
    assert_equal "DELETE /charges", @transport.target_name(@refund, operation)
    assert_equal "Payments · DELETE /charges", @transport.label(@refund, operation)
    assert_equal "the REST connector · gone", @transport.label(nil, gone)
  end

  test "call delegates to the operation caller and returns a port result" do
    context = Connectors::Context.new(project: @project, user: nil, step_run_id: 1, run_id: 2)
    caller_result = Rest::OperationCaller::Result.new(ok: true, structured: { "ok" => 1 }, status: 200, config_item_names: [])
    Rest::OperationCaller.expects(:call).with(operation: @refund, arguments: { "a" => 1 }, project: @project).returns(caller_result)

    result = @transport.call(connection: @refund, operation: @transport.operations(@refund).first, arguments: { "a" => 1 },
                             context: context)

    assert_kind_of Connectors::Result, result
    assert_equal [ true, { "ok" => 1 }, 200 ], [ result.ok?, result.structured, result.status ]
  end

  test "a JSON body that is not an object or a list comes back as its JSON text" do
    context = Connectors::Context.new(project: @project, user: nil, step_run_id: 1, run_id: 2)
    Rest::OperationCaller.stubs(:call).returns(Rest::OperationCaller::Result.new(ok: true, structured: "done", status: 200,
                                                                                config_item_names: []))

    result = @transport.call(connection: @refund, operation: @transport.operations(@refund).first, arguments: {}, context: context)

    assert_equal '"done"', result.structured
  end
end

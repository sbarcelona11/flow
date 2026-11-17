# frozen_string_literal: true

require "test_helper"

class Connectors::TransportTest < ActiveSupport::TestCase
  test "a transport without call raises NotImplementedError naming the method" do
    transport = Class.new(Connectors::Transport).new

    error = assert_raises(NotImplementedError) do
      transport.call(connection: nil, operation: nil, arguments: {}, context: nil)
    end
    assert_includes error.message, "#call"
  end

  test "every other port method raises NotImplementedError" do
    transport = Class.new(Connectors::Transport).new

    { operations: [ nil ], probe: [ nil ], owner: [ nil ], label: [ nil, nil ], connection_for: [ {}, nil ] }.each do |name, args|
      error = assert_raises(NotImplementedError, name.to_s) { transport.public_send(name, *args) }
      assert_includes error.message, "##{name}"
    end
  end
end

class Connectors::ValuesTest < ActiveSupport::TestCase
  test "context is frozen and carries ids, not a step run" do
    context = Connectors::Context.new(project: :p, user: :u, step_run_id: 1, run_id: 2)

    assert context.frozen?
    assert_equal %i[project user step_run_id run_id], Connectors::Context.members
  end

  test "result defaults" do
    result = Connectors::Result.new

    refute result.ok
    refute result.unknown
    assert_equal [], result.config_item_names
    assert_nil result.structured
    assert_not result.ok?
    assert_not result.unknown?
    assert Connectors::Result.new(ok: true).ok?
    assert Connectors::Result.new(unknown: true).unknown?
    assert_equal %i[ok structured text error unknown status config_item_names redactor], Connectors::Result.members
  end
end

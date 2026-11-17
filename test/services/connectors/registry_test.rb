# frozen_string_literal: true

require "test_helper"

class Connectors::RegistryTest < ActiveSupport::TestCase
  setup do
    @key_probe = Class.new(Connectors::Transport) { transport :registry_key_probe }
    @target_probe = Class.new(Connectors::Transport) do
      transport :registry_target_probe, target: "registry_target_probe_operation"
    end
    Connectors::Registry.reset!
    Connectors::Registry.stubs(:discovered_transports).returns([ @key_probe, @target_probe ])
  end
  teardown { Connectors::Registry.reset! }

  test "registers by key" do
    assert_equal @key_probe, Connectors::Registry.fetch(:registry_key_probe)
    assert_equal @key_probe, Connectors::Registry.fetch("registry_key_probe")
    assert_includes Connectors::Registry.keys, :registry_key_probe
  end

  test "unknown key raises naming it" do
    error = assert_raises(Connectors::Registry::Unknown) { Connectors::Registry.fetch("nope_transport") }

    assert_includes error.message, "nope_transport"
  end

  test "a nil or blank key raises Unknown" do
    assert_raises(Connectors::Registry::Unknown) { Connectors::Registry.fetch(nil) }
    assert_raises(Connectors::Registry::Unknown) { Connectors::Registry.fetch("") }
  end

  test "target mapping" do
    assert_equal @target_probe, Connectors::Registry.for_target("registry_target_probe_operation")
    error = assert_raises(Connectors::Registry::Unknown) { Connectors::Registry.for_target("no_such_target") }
    assert_includes error.message, "no_such_target"
  end

  test "anonymous classes never reach the memoized registry" do
    Class.new(Connectors::Transport) { transport :anonymous_probe }

    assert_not_includes Connectors::Registry.keys, :anonymous_probe
  end

  test "build rejects a duplicate key" do
    a = Class.new(Connectors::Transport) { transport :same, target: "a" }
    b = Class.new(Connectors::Transport) { transport :same, target: "b" }

    error = assert_raises(Connectors::Registry::DuplicateTransportError) { Connectors::Registry.build([ a, b ]) }
    assert_includes error.message, "same"
  end

  test "build rejects two transports sharing a target" do
    a = Class.new(Connectors::Transport) { transport :one, target: "shared" }
    b = Class.new(Connectors::Transport) { transport :two, target: "shared" }

    error = assert_raises(Connectors::Registry::DuplicateTransportError) { Connectors::Registry.build([ a, b ]) }
    assert_includes error.message, "shared"
  end
end

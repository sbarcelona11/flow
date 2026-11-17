# frozen_string_literal: true

require "test_helper"

class Connectors::RegistryTest < ActiveSupport::TestCase
  setup { Connectors::Registry.reset! }
  teardown { Connectors::Registry.reset! }

  test "registers by key" do
    klass = Class.new(Connectors::Transport) { transport :registry_probe }

    assert_equal klass, Connectors::Registry.fetch(:registry_probe)
    assert_equal klass, Connectors::Registry.fetch("registry_probe")
    assert_includes Connectors::Registry.keys, :registry_probe
  end

  test "unknown key raises naming it" do
    error = assert_raises(Connectors::Registry::Unknown) { Connectors::Registry.fetch("nope_transport") }

    assert_includes error.message, "nope_transport"
  end

  test "target mapping" do
    klass = Class.new(Connectors::Transport) { transport :target_probe, target: "target_probe_operation" }

    assert_equal klass, Connectors::Registry.for_target("target_probe_operation")
    error = assert_raises(Connectors::Registry::Unknown) { Connectors::Registry.for_target("no_such_target") }
    assert_includes error.message, "no_such_target"
  end
end

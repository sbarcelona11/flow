# frozen_string_literal: true

require "test_helper"

class Actions::EffectTest < ActiveSupport::TestCase
  # The same rule as app/frontend/shared/resources/mcp-servers/toolEffect.ts.
  test "an MCP tool's base effect comes from its annotations" do
    assert_equal "read", Actions::Effect.base_for_annotations({ "readOnlyHint" => true })
    assert_equal "irreversible", Actions::Effect.base_for_annotations({ "destructiveHint" => true })
    assert_equal "write", Actions::Effect.base_for_annotations({})
    assert_equal "write", Actions::Effect.base_for_annotations(nil)
    assert_equal "write", Actions::Effect.base_for_annotations({ "readOnlyHint" => "true" })
    assert_equal "read", Actions::Effect.base_for_annotations({ "readOnlyHint" => true, "destructiveHint" => true })
  end

  test "a Wrapper's base effect is write" do
    assert_equal "write", Actions::Effect.base_for_wrapper
  end

  test "at_least? orders effects read, write, send, irreversible" do
    assert Actions::Effect.at_least?("write", "write")
    assert Actions::Effect.at_least?("irreversible", "send")
    assert Actions::Effect.at_least?("send", "read")
    assert_not Actions::Effect.at_least?("read", "write")
    assert_not Actions::Effect.at_least?("send", "irreversible")
    assert_not Actions::Effect.at_least?("bogus", "read")
  end

  test "send and irreversible need an approval" do
    assert_equal [ false, false, true, true ], Step::ACTION_EFFECTS.map { |effect| Actions::Effect.needs_approval?(effect) }
  end
end

# frozen_string_literal: true

require "test_helper"

class Actions::ArgumentsTest < ActiveSupport::TestCase
  CONTEXT = { "tracker" => { "issue" => { "key" => "OPS-1", "labels" => [ "a", "b" ] } }, "count" => 3 }.freeze

  test "replaces a whole-string placeholder with the context value's type" do
    resolved = Actions::Arguments.resolve(
      { "labels" => "{{context:tracker.issue.labels}}", "count" => "{{context:count}}",
        "nested" => [ { "key" => "{{context:tracker.issue.key}}" } ], "flag" => true },
      shared_context: CONTEXT
    )

    assert_equal({ "labels" => [ "a", "b" ], "count" => 3, "nested" => [ { "key" => "OPS-1" } ], "flag" => true }, resolved)
  end

  test "replaces an inline placeholder with the value's string form" do
    resolved = Actions::Arguments.resolve(
      { "title" => "Fix {{context:tracker.issue.key}} ({{context:count}})", "tags" => "tags: {{context:tracker.issue.labels}}" },
      shared_context: CONTEXT
    )

    assert_equal({ "title" => "Fix OPS-1 (3)", "tags" => 'tags: ["a","b"]' }, resolved)
  end

  test "raises naming a missing key" do
    error = assert_raises(Actions::Arguments::Missing) do
      Actions::Arguments.resolve({ "a" => "x {{context:tracker.issue.summary}}" }, shared_context: CONTEXT)
    end

    assert_equal "tracker.issue.summary", error.key
    assert_match(/tracker\.issue\.summary/, error.message)
  end

  test "leaves text that is not a context placeholder alone" do
    arguments = { "a" => "{{config_item:KEY}}", "b" => "{{context:Bad-Key}}", "c" => nil }

    assert_equal arguments, Actions::Arguments.resolve(arguments, shared_context: nil)
  end
end

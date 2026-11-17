# frozen_string_literal: true

require "test_helper"

module Actions
  class SecretRedactorTest < ActiveSupport::TestCase
    test "replaces every exact occurrence of a secret" do
      redactor = SecretRedactor.new([ "k-123" ])

      assert_equal "key [redacted] and [redacted]", redactor.redact("key k-123 and k-123")
    end

    test "registered secrets have no length floor" do
      redactor = SecretRedactor.new([ "pin" ])

      assert_equal "the [redacted] is set", redactor.redact("the pin is set")
    end

    test "redacts a secret as it appears inside JSON text" do
      redactor = SecretRedactor.new([ 'pa"ss-word' ])

      assert_equal '{"auth":"[redacted]"}', redactor.redact({ "auth" => 'pa"ss-word' }.to_json)
    end

    test "redacts the longer secret first" do
      redactor = SecretRedactor.new([ "abc", "abc123" ])

      assert_equal "token=[redacted]", redactor.redact("token=abc123")
    end

    test "redacts string keys and values in nested structures" do
      redactor = SecretRedactor.new([ "k-123" ])

      redacted = redactor.redact({ "k-123" => [ "has k-123", 7, nil ], sym: "k-123" })

      assert_equal({ "[redacted]" => [ "has [redacted]", 7, nil ], sym: "[redacted]" }, redacted)
    end

    test "a literal header value is only a secret from eight characters" do
      redactor = SecretRedactor.new
      redactor.add_literal("short")
      redactor.add_literal("long-enough")

      assert_equal "short and [redacted]", redactor.redact("short and long-enough")
    end

    test "a literal Authorization value also registers its bare credential" do
      redactor = SecretRedactor.new
      redactor.add_literal("Bearer sk-live-abcdef12")

      assert_equal "token [redacted] is fine", redactor.redact("token sk-live-abcdef12 is fine")
    end

    test "leaves text alone without secrets and keeps nil" do
      redactor = SecretRedactor.new([ nil, "" ])

      assert_equal "nothing here", redactor.redact("nothing here")
      assert_nil redactor.redact(nil)
    end

    test "is callable as a proc" do
      redactor = SecretRedactor.new([ "k-123" ])

      assert_equal "[redacted]", redactor.call("k-123")
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Authoring
  class ToolTextTest < ActiveSupport::TestCase
    test "a line has no breaks, control, direction or separator characters, arrow look-alikes, and is capped" do
      line = ToolText.line("a\r\nb\tc ‮evil\u0000 KEY → host => x -> y z #{'q' * 300}", max: 40)

      assert_no_match(/[\r\n\t‮\u0000→ ]|=>|->/, line)
      assert_operator line.length, :<=, 40
      assert line.end_with?("…")
    end

    test "invalid bytes are replaced and never raise" do
      assert_equal "ab?c", ToolText.line("ab\xFFc".b)
    end

    test "untrusted wraps under the label and keeps nil absent" do
      assert_equal({ "untrusted_text" => "hi" }, ToolText.untrusted("hi\n"))
      assert_nil ToolText.untrusted(nil)
    end

    test "a body keeps its line breaks, loses hidden characters and is cut on a character boundary" do
      body, cut = ToolText.untrusted_body(("é" * 10) + "\nx‮", bytes: 7)

      assert cut
      assert body["untrusted_text"].valid_encoding?
      assert_operator body["untrusted_text"].bytesize, :<=, 7
      kept, = ToolText.untrusted_body("a\nb‮\u0007", bytes: 100)
      assert_equal "a\nb", kept["untrusted_text"]
    end

    test "the credential scan finds values by look and by name, and leaves ordinary text alone" do
      assert ToolText.credential_problem("pass Bearer abcdef1234567890ghij", "x")
      assert ToolText.credential_problem({ "a" => [ "ghp_a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8" ] }, "x")
      assert ToolText.credential_problem({ "Authorization" => "plain" }, "headers", named: true)
      assert_nil ToolText.credential_problem({ "Authorization" => "plain" }, "headers")
      [ "List invoices", "https://api.example.com/v1/things", "3f2b8a3e-1d3c-4f5e-9a3b-0c1d2e3f4a5b", "{{context:token}}" ].each do |text|
        assert_nil ToolText.credential_problem(text, "x", named: true), text
      end
    end
  end
end

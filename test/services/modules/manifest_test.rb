# frozen_string_literal: true

require "test_helper"

module Modules
  class ManifestTest < ActiveSupport::TestCase
    def block_hash(**overrides)
      { "kind" => "block", "namespace" => "acme", "slug" => "send-invoice", "version" => 1, "label" => "Send invoice",
        "executor" => "action",
        "ports" => { "in" => { "amount" => "aixle/money@1" }, "out" => { "receipt" => "aixle/file@1" } },
        "config" => { "type" => "object", "properties" => { "note" => { "type" => "string" } } },
        "uses" => { "transport" => "rest", "connection" => "billing", "operation" => "create_invoice" } }.merge(overrides)
    end

    def invalid_message(text)
      error = assert_raises(Manifest::Invalid) { Manifest.parse(text) }
      error.message
    end

    test "parses a block" do
      manifest = Manifest.parse(JSON.generate(block_hash(effect: "send")))

      assert_equal "acme/send-invoice@1", manifest.key
      assert_equal "action", manifest.executor
      assert_equal "send", manifest.effect
      assert_equal({ "transport" => "rest", "connection" => "billing", "operation" => "create_invoice" }, manifest.uses)
      assert_equal "aixle/money@1", manifest.ports.dig("in", "amount")
    end

    test "parses a block written as YAML" do
      yaml = <<~YAML
        kind: block
        namespace: acme
        slug: approve
        version: 2
        label: Approve
        executor: control
        control: approval
        ports:
          in: { subject: "list<aixle/string@1>" }
          out: { decision: aixle/string@1 }
      YAML

      manifest = Manifest.parse(yaml)

      assert_equal "approval", manifest.control
      assert_equal 2, manifest.version
    end

    test "parses a type and a capability" do
      type = Manifest.parse(JSON.generate("kind" => "type", "namespace" => "acme", "slug" => "sku", "version" => 1,
                                          "label" => "SKU", "schema" => { "type" => "string", "pattern" => "^[A-Z]+$" }))
      capability = Manifest.parse(JSON.generate("kind" => "capability", "namespace" => "acme", "slug" => "invoice",
                                                "version" => 1, "label" => "Invoice", "input" => "acme/sku@1",
                                                "output" => "list<aixle/file@1>"))

      assert_equal "string", type.schema["type"]
      assert_equal "list<aixle/file@1>", capability.output
    end

    test "parses an agent block" do
      manifest = Manifest.parse(JSON.generate(
                                  "kind" => "block", "namespace" => "acme", "slug" => "triage", "version" => 1, "label" => "Triage",
                                  "executor" => "agent", "agent" => { "runtime" => Step::SUPPORTED_AGENT_RUNTIMES.first, "persona" => "Analyst" },
                                  "mandate" => "Sort the incoming tickets by urgency.",
                                  "ports" => { "in" => {}, "out" => { "ranked" => "list<aixle/string@1>" } }
                                ))

      assert_equal "Analyst", manifest.agent["persona"]
    end

    test "refuses an unknown agent runtime" do
      text = JSON.generate("kind" => "block", "namespace" => "acme", "slug" => "triage", "version" => 1, "label" => "T",
                           "executor" => "agent", "agent" => { "runtime" => "bash" }, "mandate" => "x",
                           "ports" => { "in" => {}, "out" => {} })

      assert_match(/agent.runtime must be one of/, invalid_message(text))
    end

    test "refuses YAML aliases" do
      yaml = <<~YAML
        kind: type
        namespace: acme
        slug: sku
        version: 1
        label: &label SKU
        description: *label
        schema: { type: string }
      YAML

      assert_match(/aliases/, invalid_message(yaml))
    end

    test "refuses a manifest over 256 KB before parsing" do
      Psych.stub(:parse, ->(*) { flunk "parsed an oversized manifest" }) do
        assert_match(/larger than 256 KB/, invalid_message("a: #{'x' * 257.kilobytes}"))
      end
    end

    test "refuses depth over 32 in bounded time" do
      deep_json = ("{\"a\":" * 40) + "1" + ("}" * 40)
      deep_yaml = (0..40).map { |i| "#{'  ' * i}a:" }.join("\n") + " 1"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_match(/deeper than 32/, invalid_message(deep_json))
      assert_match(/deeper than 32/, invalid_message(deep_yaml))
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    end

    test "refuses node-budget explosions in bounded time" do
      wide_json = "{\"kind\":\"type\",\"a\":[#{([ '1' ] * 100_000).join(',')}]}"
      wide_yaml = "kind: type\na: [#{([ '1' ] * 100_000).join(',')}]"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_match(/more than 10000 values/, invalid_message(wide_json))
      assert_match(/more than 10000 values/, invalid_message(wide_yaml))
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    end

    test "refuses additional properties" do
      assert_match(/script/, invalid_message(JSON.generate(block_hash("script" => "puts 1"))))
      assert_match(/url/, invalid_message(JSON.generate(block_hash("uses" => block_hash["uses"].merge("url" => "https://x.test")))))
      assert_match(/extra/, invalid_message(JSON.generate(block_hash("ports" => { "in" => {}, "out" => {}, "extra" => {} }))))
    end

    test "refuses a block missing what its executor needs" do
      assert_match(/mandate/, invalid_message(JSON.generate(block_hash("executor" => "agent", "uses" => nil).compact.merge("agent" => { "runtime" => "claude" }))))
    end

    test "refuses text longer than 2,000 characters" do
      assert_match(/description/, invalid_message(JSON.generate(block_hash("description" => "x" * 2_001))))
      assert Manifest.parse(JSON.generate(block_hash("description" => "x" * 2_000)))
    end

    test "refuses a mandate over 8 KB" do
      text = JSON.generate("kind" => "block", "namespace" => "acme", "slug" => "triage", "version" => 1, "label" => "T",
                           "executor" => "agent", "agent" => { "runtime" => Step::SUPPORTED_AGENT_RUNTIMES.first },
                           "mandate" => "x" * 9_000, "ports" => { "in" => {}, "out" => {} })

      assert_match(/mandate is larger than 8 KB/, invalid_message(text))
    end

    test "refuses malformed references and versions" do
      assert_match(/in\.amount/, invalid_message(JSON.generate(block_hash("ports" => { "in" => { "amount" => "aixle/money" }, "out" => {} }))))
      assert_match(/version/, invalid_message(JSON.generate(block_hash("version" => 0))))
    end

    test "refuses an invalid effect" do
      assert_match(/effect/, invalid_message(JSON.generate(block_hash("effect" => "none"))))
    end

    test "refuses a config with $ref or credentials in defaults" do
      ref = block_hash("config" => { "type" => "object", "properties" => { "a" => { "$ref" => "http://evil.test/x" } } })
      assert_match(/unsupported keyword \$ref/, invalid_message(JSON.generate(ref)))

      secret = block_hash("config" => { "type" => "object", "properties" => { "api_key" => { "type" => "string", "default" => "abc" } } })
      assert_match(/credentials/, invalid_message(JSON.generate(secret)))

      token = block_hash("config" => { "type" => "object", "properties" => { "x" => { "type" => "string", "default" => "Bearer abcdefghijk" } } })
      assert_match(/credentials/, invalid_message(JSON.generate(token)))
    end

    test "refuses a config over 16 KB" do
      big = block_hash("config" => { "type" => "object", "description" => "x" * 17_000 })

      assert_match(/config is larger than 16 KB/, invalid_message(JSON.generate(big)))
    end

    test "refuses non-objects, unknown kinds and bad encodings" do
      assert_match(/must be an object/, invalid_message("- a\n- b"))
      assert_match(/kind must be one of/, invalid_message(JSON.generate("kind" => "connector")))
      assert_match(/not valid JSON or YAML/, invalid_message("{not json"))
      assert_match(/UTF-8/, invalid_message("kind: \xFF"))
    end

    test "refuses YAML object tags" do
      assert_match(/not accepted/, invalid_message("kind: !ruby/object:Object {}"))
    end

    test "the digest is stable across key order" do
      a = Manifest.from_hash(block_hash)
      b = Manifest.from_hash(block_hash.to_a.reverse.to_h)

      assert_equal a.digest, b.digest
      assert_match(/\A\h{64}\z/, a.digest)
    end
  end
end

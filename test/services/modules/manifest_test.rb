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

    test "a block can declare the cost of one call in cents" do
      assert_equal 40, Manifest.parse(JSON.generate(block_hash("cost_cents" => 40))).cost_cents
      assert_equal 0, Manifest.parse(JSON.generate(block_hash("cost_cents" => 0))).cost_cents
      assert_equal 1_000_000, Manifest.parse(JSON.generate(block_hash("cost_cents" => 1_000_000))).cost_cents
      assert_nil Manifest.parse(JSON.generate(block_hash)).cost_cents
    end

    test "refuses a cost that is negative, too large or not a whole number" do
      [ -1, 1_000_001, 1.5, "40", nil ].each do |cents|
        assert_match(/cost_cents/, invalid_message(JSON.generate(block_hash("cost_cents" => cents))), cents.inspect)
      end
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

    def type_json(**overrides)
      JSON.generate({ "kind" => "type", "namespace" => "acme", "slug" => "sku", "version" => 1, "label" => "SKU",
                      "schema" => { "type" => "string" } }.merge(overrides.stringify_keys))
    end

    test "refuses values that would crash later processing as Invalid" do
      yaml_head = "kind: type\nnamespace: acme\nslug: sku\nversion: 1\nlabel: SKU\n"

      assert_match(/not finite/, invalid_message("#{yaml_head}schema: { x: .inf }"))
      assert_match(/not finite/, invalid_message("#{yaml_head}schema: { x: .nan }"))
      assert_kind_of String, invalid_message("{\"kind\":\"type\",\"x\":1e400}")
      assert_match(/not valid UTF-8/, invalid_message("#{yaml_head}schema: { x: !!binary \"/w==\" }"))
      assert_match(/unsupported keyword \$schema/, invalid_message(type_json(schema: { "$schema" => "http://example.test/s" })))
      %w[$id $anchor $recursiveRef $dynamicRef $dynamicAnchor $ref].each do |keyword|
        assert_match(/unsupported keyword/, invalid_message(type_json(schema: { "properties" => { "a" => { keyword => "x" } } })))
      end
    end

    test "any unexpected error while checking becomes Invalid" do
      SchemaHygiene.stub(:errors_for, ->(*) { raise IOError, "boom" }) do
        assert_match(/could not be processed/, invalid_message(type_json))
      end
    end

    test "names are anchored to the whole string" do
      assert_match(/namespace|name/, invalid_message(type_json(namespace: "aixle\n")))
      assert_match(/slug|name/, invalid_message(type_json(slug: "sku\n")))
      ports = { "in" => { "ok\n<script>x</script>" => "aixle/string@1" }, "out" => {} }
      assert_match(/port|ok/, invalid_message(JSON.generate(block_hash("ports" => ports))))
      assert_match(/transport/, invalid_message(JSON.generate(block_hash("uses" => block_hash["uses"].merge("transport" => "rest\nx")))))
      assert_match(/reference|pattern/, invalid_message(JSON.generate(block_hash("ports" => { "in" => { "a" => "aixle/money@1\n" }, "out" => {} }))))
    end

    test "built-in patterns cannot match multi-line input" do
      money = Registry.builtin_types.find { |m| m.slug == "money" }
      schema = JSONSchemer.schema(money.schema, regexp_resolver: "ecma")

      assert schema.valid?({ "amount" => "12.50", "currency" => "USD" })
      assert_not schema.valid?({ "amount" => "12.50", "currency" => "USD\nxx" })
      assert_not schema.valid?({ "amount" => "1\n2", "currency" => "USD" })
      ruby = Regexp.new(money.schema.dig("properties", "currency", "pattern"))
      assert_not ruby.match?("USD\nxx")
      assert_not ruby.match?("xx\nUSD")
    end

    test "error messages are bounded and carry no raw markup" do
      long = "<b>#{'x' * 200_000}"
      message = invalid_message(type_json(long => 1))

      assert_operator message.length, :<=, 1_000
      assert_no_match(/[<>]/, message)
    end

    test "refuses patterns that are not linear-time or not valid" do
      assert_match(/pattern/, invalid_message(type_json(schema: { "type" => "string", "pattern" => "(a+)\\1$" })))
      assert_match(/pattern/, invalid_message(type_json(schema: { "type" => "string", "pattern" => "(" })))
      assert_match(/pattern/, invalid_message(type_json(schema: { "patternProperties" => { "(a+)\\1" => {} } })))
      assert_match(/format regex/, invalid_message(type_json(schema: { "type" => "string", "format" => "regex" })))
      config = block_hash("config" => { "type" => "object", "properties" => { "a" => { "type" => "string", "pattern" => "(?=a)a*(a+)\\1" } } })
      assert_match(/pattern/, invalid_message(JSON.generate(config)))
      assert Manifest.parse(type_json(schema: { "type" => "string", "pattern" => "^[A-Z]{3}$" }))
    end

    test "versions are bounded to a 32-bit integer" do
      assert_match(/version/, invalid_message(type_json(version: 2_147_483_648)))
      assert_match(/version/, invalid_message(type_json(version: 99_999_999_999_999_999_999)))
      assert_match(/reference|ports/, invalid_message(JSON.generate(block_hash("ports" => { "in" => { "a" => "aixle/string@2147483648" }, "out" => {} }))))
      assert Manifest.parse(type_json(version: 2_147_483_647))
    end

    test "refuses more than one YAML document" do
      assert_match(/more than one YAML document/, invalid_message("#{YAML.dump(JSON.parse(type_json))}---\nkind: type\n"))
    end

    test "accepts a leading byte order mark" do
      assert_equal "acme/sku@1", Manifest.parse("﻿#{type_json}").key
      assert_equal "acme/sku@1", Manifest.parse("﻿#{YAML.dump(JSON.parse(type_json))}").key
    end

    test "free text must be plain text" do
      assert_match(/label must be plain text|NUL/, invalid_message(type_json(label: "a\u0000b")))
      assert_match(/label must be plain text/, invalid_message(type_json(label: "a\nb")))
      assert_match(/description must be plain text|NUL/, invalid_message(type_json(description: "a\u0000b")))
      assert Manifest.parse(type_json(description: "line one\nline two"))
      agent = { "kind" => "block", "namespace" => "acme", "slug" => "t", "version" => 1, "label" => "T", "executor" => "agent",
                "agent" => { "runtime" => Step::SUPPORTED_AGENT_RUNTIMES.first, "persona" => "a\u0000b" }, "mandate" => "x",
                "ports" => { "in" => {}, "out" => {} } }
      assert_match(/persona must be plain text|NUL/, invalid_message(JSON.generate(agent)))
      assert_match(/mandate must be plain text|NUL/, invalid_message(JSON.generate(agent.merge("agent" => { "runtime" => Step::SUPPORTED_AGENT_RUNTIMES.first }, "mandate" => "a\u0000"))))
    end

    test "credential-looking values are refused in const, enum and examples too" do
      %w[const enum examples].each do |keyword|
        value = keyword == "const" ? "Bearer abcdefghijk" : [ "ok", "Bearer abcdefghijk" ]
        config = block_hash("config" => { "type" => "object", "properties" => { "x" => { "type" => "string", keyword => value } } })
        assert_match(/credentials/, invalid_message(JSON.generate(config)), keyword)
      end
    end

    test "the manifest data is deeply frozen" do
      manifest = Manifest.from_hash(block_hash)

      assert manifest.data.frozen?
      assert manifest.ports.frozen?
      assert manifest.ports["in"].frozen?
      assert Registry.builtin_types.all? { |m| m.data.frozen? && m.schema.frozen? } && Registry.builtin_types.frozen?
    end

    test "format_version defaults to 1 and any other value is unsupported" do
      assert Manifest.parse(type_json)
      assert_equal 1, Manifest.parse(type_json(format_version: 1)).format_version
      assert_match(/Unsupported manifest format version 2/, invalid_message(type_json(format_version: 2)))
      assert_match(/Unsupported manifest format version "x"/, invalid_message(type_json(format_version: "x")))
    end

    test "only capabilities may have dots in the slug" do
      capability = { "kind" => "capability", "namespace" => "acme", "slug" => "image.generate", "version" => 1,
                     "label" => "Image", "input" => "aixle/string@1", "output" => "aixle/file@1" }

      assert_equal "acme/image.generate@1", Manifest.parse(JSON.generate(capability)).key
      assert_match(/slug/, invalid_message(type_json(slug: "image.generate")))
      assert_match(/slug/, invalid_message(JSON.generate(block_hash("slug" => "image.generate"))))
      uses = block_hash("executor" => "action", "uses" => { "capability" => "acme/image.generate@1" })
      assert Manifest.parse(JSON.generate(uses))
      assert_match(/reference|pattern/, invalid_message(JSON.generate(block_hash("ports" => { "in" => { "a" => "acme/image.generate@1" }, "out" => {} }))))
    end

    test "YAML tags that fail to construct are Invalid, not exceptions" do
      assert_match(/could not be read|not accepted/, invalid_message("kind: !!float 'x'\n"))
      assert_kind_of String, invalid_message("kind: type\nschema:\n  nested: [ !!float 'x' ]\n")
    end

    test "NUL, line separators and bidirectional controls are refused in every string and key" do
      [ "a\u0000b", "a b", "a b", "a‮b", "a⁦b" ].each do |bad|
        assert_match(/NUL|bidirectional/, invalid_message(type_json(schema: { "title" => bad })), bad.inspect)
        assert_match(/NUL|bidirectional/, invalid_message(type_json(schema: { "enum" => [ bad ] })))
        assert_match(/NUL|bidirectional/, invalid_message(type_json(schema: { "properties" => { bad => {} } })))
        assert_match(/NUL|bidirectional/, invalid_message(JSON.generate(block_hash("config" => { "description" => bad }))))
      end
    end

    test "version and format_version must be whole numbers" do
      assert_match(/whole number|version/, invalid_message(type_json(version: 1.0)))
      assert_match(/Unsupported manifest format version 1.0/, invalid_message(type_json(format_version: 1.0)))
    end

    test "schema keywords like $id are refused but property names are not" do
      assert_match(/unsupported keyword \$id/, invalid_message(type_json(schema: { "$id" => "x" })))
      assert_match(/unsupported keyword \$anchor/, invalid_message(type_json(schema: { "properties" => { "a" => { "$anchor" => "x" } } })))
      assert Manifest.parse(type_json(schema: { "type" => "object", "properties" => { "$id" => { "type" => "string" }, "$anchor" => {} } }))
      assert Manifest.parse(type_json(schema: { "type" => "object", "default" => { "$id" => 1 } }))
    end

    test "long messages keep their actionable end" do
      message = invalid_message(type_json("x" * 5_000 => 1))

      assert_operator message.length, :<=, 1_000
      assert_match(/disallowed additional property\z/, message)
    end

    test "Invalid is safe for odd messages" do
      assert_equal "Modules::Manifest::Invalid", Manifest::Invalid.new.message
      assert_equal "Modules::Manifest::Invalid", Manifest::Invalid.new("").message
      assert_kind_of String, Manifest::Invalid.new("héllo <b>".encode(Encoding::UTF_16LE)).message
      assert_kind_of String, Manifest::Invalid.new("\xFF\xFE".b).message
      assert_equal "Modules::Manifest::Invalid", Manifest::Invalid.new(BasicObject.new).message
    end

    test "the digest is stable across key order" do
      a = Manifest.from_hash(block_hash)
      b = Manifest.from_hash(block_hash.to_a.reverse.to_h)

      assert_equal a.digest, b.digest
      assert_match(/\A\h{64}\z/, a.digest)
    end
  end
end

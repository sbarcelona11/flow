# frozen_string_literal: true

require "test_helper"

module Modules
  class CompositeManifestTest < ActiveSupport::TestCase
    def graph
      [ { "key" => "fetch", "kind" => "action", "name" => "Fetch",
          "kind_config" => { "target" => "rest_operation", "api_operation_id" => 1, "effect" => "read", "output_name" => "invoice.json",
                             "arguments" => { "id" => "{{port:invoice_id}}", "note" => "static" } } },
        { "key" => "summarise", "kind" => "agent", "name" => "Summarise", "depends_on" => [ "fetch" ],
          "instructions" => "Summarise {{output:fetch:invoice.json}} for {{port:audience}}",
          "output_asset_specs" => [ { "name" => "summary.md" } ] } ]
    end

    def composite(steps: graph, ports: nil, **overrides)
      { "kind" => "block", "namespace" => "local", "slug" => "invoice-flow", "version" => 1, "label" => "Invoice flow",
        "executor" => "composite",
        "ports" => ports || { "in" => { "invoice_id" => { "type" => "aixle/string@1" }, "audience" => { "description" => "Who reads it" } },
                              "out" => { "summary" => { "step" => "summarise", "output" => "summary.md" } } },
        "graph" => { "steps" => steps } }.merge(overrides)
    end

    def refused(hash)
      assert_raises(Manifest::Invalid) { Manifest.from_hash(hash) }.message
    end

    def with_step(index, **changes) = graph.each_with_index.map { |step, i| i == index ? step.merge(changes) : step }

    test "a composite parses and keeps its graph and ports" do
      manifest = Manifest.from_hash(composite)

      assert_equal "composite", manifest.executor
      assert_equal %w[fetch summarise], manifest.graph["steps"].pluck("key")
      assert_equal "summarise", manifest.ports.dig("out", "summary", "step")
    end

    test "the schema's step cap mirrors Composite::MAX_STEPS" do
      steps = Array.new(Composite::MAX_STEPS) { |i| { "key" => "s#{i}", "kind" => "agent", "name" => "S#{i}" } }
      assert Manifest.from_hash(composite(steps: steps, ports: { "in" => {}, "out" => {} }))

      assert_match(/maxItems|more than|20/i, refused(composite(steps: steps + [ { "key" => "extra", "kind" => "agent", "name" => "X" } ],
                                                              ports: { "in" => {}, "out" => {} })))
    end

    test "a graph with no steps, a repeated key or an unknown dependency is refused" do
      refused(composite(steps: [], ports: { "in" => {}, "out" => {} }))
      assert_match(/used twice/, refused(composite(steps: [ graph.first, graph.first ], ports: { "in" => { "invoice_id" => {} }, "out" => {} })))
      assert_match(/not in the graph/, refused(composite(steps: with_step(1, "depends_on" => [ "ghost" ]))))
    end

    test "a cyclic graph is refused" do
      assert_match(/wait on each other/, refused(composite(steps: with_step(0, "depends_on" => [ "summarise" ]))))
    end

    test "an output reference to a key outside the graph, a file it does not declare or a step it does not depend on is refused" do
      assert_match(/ghost.*not in the graph/, refused(composite(steps: with_step(1, "instructions" => "{{output:ghost:x.md}} {{port:audience}}"))))
      assert_match(/does not declare an output nope.md/, refused(composite(steps: with_step(1, "instructions" => "{{output:fetch:nope.md}} {{port:audience}}"))))
      assert_match(/without depending/, refused(composite(steps: with_step(1, "depends_on" => []))))
    end

    test "a port must be declared, and in an argument it must be the whole value" do
      assert_match(/ports.in does not declare/, refused(composite(steps: with_step(1, "instructions" => "{{port:undeclared}}"))))
      longer = graph.first.deep_merge("kind_config" => { "arguments" => { "id" => "id-{{port:invoice_id}}" } })
      assert_match(/whole value/, refused(composite(steps: [ longer, graph.last ])))
    end

    test "a port token outside instructions and arguments is refused" do
      assert_match(/only instructions and action arguments/, refused(composite(steps: with_step(1, "name" => "Summarise {{port:audience}}"))))
    end

    test "an out port naming an unknown step or an undeclared output is refused" do
      ports = ->(step, output) { { "in" => { "invoice_id" => {}, "audience" => {} }, "out" => { "summary" => { "step" => step, "output" => output } } } }
      assert_match(/not in the graph/, refused(composite(ports: ports.call("ghost", "summary.md"))))
      assert_match(/does not declare/, refused(composite(ports: ports.call("summarise", "other.md"))))
    end

    test "a composite cannot nest another composite or hold a Wrapper action" do
      nested = graph.first.merge("composite" => { "ref" => "local/x@1", "instance" => SecureRandom.uuid, "node" => "a" })
      refused(composite(steps: [ nested, graph.last ]))

      wrapper = graph.first.deep_merge("kind_config" => { "target" => "wrapper", "tool_id" => 3 })
      assert_match(/Wrapper/, refused(composite(steps: [ wrapper, graph.last ])))
    end

    test "a send or irreversible action needs a blocking approval inside the block" do
      send_step = { "key" => "mail", "kind" => "action", "name" => "Mail",
                    "kind_config" => { "target" => "rest_operation", "api_operation_id" => 1, "effect" => "send" } }
      ports = { "in" => {}, "out" => {} }
      assert_match(/must depend on an approval/, refused(composite(steps: [ send_step ], ports: ports)))

      approval = { "key" => "ok", "kind" => "approval", "name" => "OK", "kind_config" => { "timeout_seconds" => 3600, "on_timeout" => "skip" } }
      assert_match(/must depend on an approval/, refused(composite(steps: [ approval, send_step.merge("depends_on" => [ "ok" ]) ], ports: ports)))

      blocking = approval.merge("kind_config" => { "timeout_seconds" => 3600, "on_timeout" => "fail" })
      assert Manifest.from_hash(composite(steps: [ blocking, send_step.merge("depends_on" => [ "ok" ]) ], ports: ports))
    end

    test "credentials in instructions or in an argument named like a secret are refused, placeholders are not" do
      assert_match(/credentials/, refused(composite(steps: with_step(1, "instructions" => "use sk-abcdefghijklmnop1234 {{port:audience}}"))))
      leaky = graph.first.deep_merge("kind_config" => { "arguments" => { "api_key" => "hunter2hunter2" } })
      assert_match(/credentials/, refused(composite(steps: [ leaky, graph.last ])))
      fine = graph.first.deep_merge("kind_config" => { "arguments" => { "api_key" => "{{context:key}}" } })
      assert Manifest.from_hash(composite(steps: [ fine, graph.last ]))
    end

    test "a port with a bad type reference or name is refused" do
      refused(composite(ports: { "in" => { "invoice_id" => { "type" => "nope" }, "audience" => {} }, "out" => {} }))
      refused(composite(ports: { "in" => { "Bad Name" => {} }, "out" => {} }))
    end

    test "NUL and bidirectional characters in a graph are refused before the schema runs" do
      assert_match(/NUL|bidirectional/, refused(composite(steps: with_step(1, "instructions" => "x‮y"))))
      assert_match(/NUL|bidirectional/, refused(composite(steps: with_step(1, "name" => "a\u0000b"))))
    end

    test "a composite over 256 KB is refused before it is parsed" do
      assert_match(/larger than 256 KB/, assert_raises(Manifest::Invalid) { Manifest.parse("x" * (Manifest::MAX_BYTES + 1)) }.message)
    end

    test "a composite has no uses and no effect" do
      refused(composite("uses" => { "transport" => "rest", "connection" => "a", "operation" => "b" }))
      refused(composite("effect" => "read"))
    end
  end
end

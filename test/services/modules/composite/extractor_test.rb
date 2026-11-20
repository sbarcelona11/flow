# frozen_string_literal: true

require "test_helper"

module Modules
  module Composite
    class ExtractorTest < ActiveSupport::TestCase
      include CompositeHelper

      setup do
        build_composite_project
        build_pipeline
      end

      def extract(steps, label: "Invoice flow", **options)
        Extractor.new(workflow: @workflow, step_ids: steps.map(&:id), label: label, **options).manifest
      end

      def refused(steps, **options)
        assert_raises(Extractor::Invalid) { extract(steps, **options) }.message
      end

      test "a selection that governs itself becomes a manifest that parses, with ports from what crosses the boundary" do
        manifest = extract([ @summarise, @approve, @send ]).manifest

        assert_equal "composite", manifest["executor"]
        assert_equal "local/invoice-flow@1", Manifest.from_hash(manifest).key
        assert_equal %w[summarise approve send_invoice], manifest.dig("graph", "steps").pluck("key")
        assert_equal [ "fetch_invoice_invoice" ], manifest.dig("ports", "in").keys
        assert_equal "Fetch invoice: invoice.json", manifest.dig("ports", "in", "fetch_invoice_invoice", "description")
        assert_equal "Summarise {{port:fetch_invoice_invoice}}", manifest.dig("graph", "steps", 0, "instructions")
        assert_equal({ "body" => "{{output:summarise:summary.md}}" }, manifest.dig("graph", "steps", 2, "kind_config", "arguments"))
        assert_equal [ "approve" ], manifest.dig("graph", "steps", 2, "depends_on")
        assert_equal 40, manifest.dig("graph", "steps", 0, "budget_cents")
      end

      test "an external dependency with no token is a port the steps wait on" do
        @summarise.update!(instructions: "Summarise it")

        manifest = extract([ @summarise, @approve, @send ]).manifest

        assert_equal [ "port:fetch_invoice" ], manifest.dig("graph", "steps", 0, "depends_on")
        assert_equal "Runs after Fetch invoice", manifest.dig("ports", "in", "fetch_invoice", "description")
      end

      test "an output an unselected step reads becomes an out port, and more can be asked for" do
        create(:step, workflow: @workflow, name: "Report", position: 5, depends_on_step_ids: [ @summarise.id ],
                      instructions: "Report {{output:#{@summarise.id}:summary.md}}")

        assert_equal({ "summarise_summary" => { "step" => "summarise", "output" => "summary.md" } },
                     extract([ @fetch, @summarise ]).manifest.dig("ports", "out"))
        asked = extract([ @fetch, @summarise ], out_ports: [ { step_id: @fetch.id, output: "invoice.json" } ])
        assert_equal %w[fetch_invoice_invoice summarise_summary], asked.manifest.dig("ports", "out").keys.sort
      end

      test "an out port for an output the step does not declare is refused" do
        assert_match(/does not declare an output nope.md/,
                     refused([ @fetch, @summarise ], out_ports: [ { step_id: @summarise.id, output: "nope.md" } ]))
      end

      test "a selection missing the approval of a send action is refused by naming the step to include" do
        assert_equal "Include the approval step Approve in the block: Send invoice (send) must run after it.", refused([ @summarise, @send ])
      end

      test "more than twenty steps are refused" do
        steps = Array.new(21) { |i| create(:step, workflow: @workflow, name: "Extra #{i}", position: 10 + i) }

        assert_equal "A block holds at most 20 steps; you picked 21.", refused(steps)
      end

      test "an empty or repeated selection, an unnamed block and foreign steps are refused" do
        assert_match(/at least one/, refused([]))
        assert_match(/once/, refused([ @fetch, @fetch ]))
        assert_match(/Give the block a name/, refused([ @fetch ], label: " "))
        other = create(:step, workflow: create(:workflow, scope: @project), position: 1)
        assert_match(/not in this workflow/, refused([ other ]))
      end

      test "a Wrapper action is refused" do
        tool = create(:tool, scope: @project, name: "wrapper_tool")
        wrapper = create(:step, workflow: @workflow, name: "Wrapped", position: 9, kind: "action",
                                kind_config: { "target" => "wrapper", "tool_id" => tool.id, "effect" => "write" })

        assert_match(/Wrapper action/, refused([ wrapper ]))
      end

      test "an external output inside a longer argument string is refused rather than guessed" do
        @send.update!(kind_config: @send.kind_config.merge("arguments" => { "body" => "x {{output:#{@fetch.id}:invoice.json}}" }),
                      depends_on_step_ids: [ @approve.id, @fetch.id ])

        assert_match(/inside a longer argument/, refused([ @summarise, @approve, @send ]))
      end

      test "a selection that contains an inserted instance is saved as plain steps with a warning" do
        @fetch.update!(composite: { "ref" => "local/old@1", "instance" => SecureRandom.uuid, "node" => "fetch" })

        result = extract([ @fetch, @summarise ])

        assert_equal 1, result.warnings.size
        assert result.manifest.dig("graph", "steps").none? { |step| step.key?("composite") }
      end

      test "a second block from the same label gets a free slug" do
        stamp_composite(extract([ @fetch ]).manifest)

        assert_equal "invoice-flow-2", extract([ @fetch ]).manifest["slug"]
      end
    end
  end
end

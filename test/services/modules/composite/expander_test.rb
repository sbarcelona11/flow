# frozen_string_literal: true

require "test_helper"

module Modules
  module Composite
    class ExpanderTest < ActiveSupport::TestCase
      include CompositeHelper

      setup do
        build_composite_project
        build_pipeline
        @manifest = Extractor.new(workflow: @workflow, step_ids: [ @summarise.id, @approve.id, @send.id ], label: "Invoice flow").manifest.manifest
        @definition = stamp_composite(@manifest)
        @target = create(:workflow, scope: @project, name: "Target")
        @upstream = create(:step, workflow: @target, name: "Upstream", position: 1, kind: "action",
                                  kind_config: rest_config("read", "output_name" => "doc.json"))
      end

      def expand(bindings: { "fetch_invoice_invoice" => "{{output:#{@upstream.id}:doc.json}}" }, **options)
        Expander.new(project: @project, ref: "local/invoice-flow@1", bindings: bindings, **options).call
      end

      test "expansion yields ordinary steps with fresh keys, rewritten tokens, dependencies and provenance" do
        result = expand(first_index: 3)
        summarise, approve, send = result.steps

        assert_equal %w[new-3 new-4 new-5], result.steps.pluck("key")
        assert_equal "Summarise {{output:#{@upstream.id}:doc.json}}", summarise["instructions"]
        assert_equal [ @upstream.id ], summarise["depends_on_step_ids"]
        assert_equal [ "new-3" ], approve["depends_on_step_ids"]
        assert_equal [ "new-4" ], send["depends_on_step_ids"]
        assert_equal({ "body" => "{{output:new-3:summary.md}}" }, send["kind_config"]["arguments"])
        assert_equal({ "ref" => "local/invoice-flow@1", "instance" => result.instance, "node" => "summarise" }, summarise["composite"])
        assert_equal 40, summarise["budget_cents"]
        assert_equal [], result.unbound
        assert_empty result.warnings
      end

      test "unbound ports become empty in an argument and the port name in instructions" do
        result = expand(bindings: {})

        assert_equal "Summarise fetch_invoice_invoice", result.steps.first["instructions"]
        assert_equal [ "fetch_invoice_invoice" ], result.unbound
        assert_equal [], result.steps.first["depends_on_step_ids"]
      end

      test "canvas positions are assigned by dependency depth from the requested origin" do
        result = expand(at: { x: 100, y: 50 })

        assert_equal [ { "x" => 100, "y" => 50 }, { "x" => 420, "y" => 50 }, { "x" => 740, "y" => 50 } ], result.steps.pluck("canvas_position")
      end

      test "a port that waits on an external step adds the dependency when bound" do
        @summarise.update!(instructions: "Summarise it")
        stamp_composite(Extractor.new(workflow: @workflow, step_ids: [ @summarise.id, @approve.id, @send.id ], label: "Waiting").manifest.manifest)

        result = Expander.new(project: @project, ref: "local/waiting@1", bindings: { "fetch_invoice" => "{{step:#{@upstream.id}}}" }).call

        assert_equal [ @upstream.id ], result.steps.first["depends_on_step_ids"]
      end

      test "an unknown port, a nested port token or oversized text is refused" do
        assert_raises(Expander::Refused) { expand(bindings: { "nope" => "x" }) }
        assert_raises(Expander::Refused) { expand(bindings: { "fetch_invoice_invoice" => "{{port:other}}" }) }
        assert_raises(Expander::Refused) { expand(bindings: { "fetch_invoice_invoice" => "x" * 5000 }) }
      end

      test "a disabled, unreviewed or unknown block is refused" do
        @definition.update!(enabled: false)
        assert_raises(ActiveRecord::RecordNotFound) { expand }

        @definition.update!(enabled: true)
        @definition.update_columns(reviewed_at: nil, enabled: false)
        assert_raises(ActiveRecord::RecordNotFound) { expand }
        assert_raises(ActiveRecord::RecordNotFound) { Expander.new(project: @project, ref: "local/ghost@1").call }
        assert_raises(ActiveRecord::RecordNotFound) { Expander.new(project: @project, ref: "garbage").call }
      end

      test "another project's composite is not found" do
        other = create(:project, company: @company, owner: @user)

        assert_raises(ActiveRecord::RecordNotFound) { Expander.new(project: other, ref: "local/invoice-flow@1").call }
      end

      test "a composite naming another project's REST operation is refused as invalid" do
        foreign = create(:api_operation, api_connector: create(:api_connector, scope: create(:project, company: @company, owner: @user), name: "x"))
        manifest = @manifest.deep_dup.merge("slug" => "foreign")
        manifest["graph"]["steps"][2]["kind_config"]["api_operation_id"] = foreign.id
        definition = build(:module_definition, scope: @project, kind: "block", namespace: "local", slug: "foreign", manifest: manifest)

        assert_not definition.valid?
        assert_match(/REST operation #{foreign.id}/, definition.errors[:manifest].join)
        definition.save!(validate: false)
        error = assert_raises(Expander::Refused) { Expander.new(project: @project, ref: "local/foreign@1").call }
        assert_match(/can't be used/, error.message)
      end

      test "resource ids that no longer exist are dropped with a warning" do
        skill = create(:skill, scope: @project)
        manifest = @manifest.deep_dup.merge("slug" => "skilled")
        manifest["graph"]["steps"][0]["skill_ids"] = [ skill.id ]
        stamp_composite(manifest)
        skill.destroy!

        result = Expander.new(project: @project, ref: "local/skilled@1").call

        assert_nil result.steps.first["skill_ids"].presence
        assert_equal 1, result.warnings.size
      end

      test "the expanded steps save through the aggregate and pass Versions.verify!" do
        result = expand
        payload = { "steps" => [ { "id" => @upstream.id, "name" => "Upstream" } ] + result.steps.map { |s| s.merge("depends_on_step_ids" => s["depends_on_step_ids"]) } }
        actor = Versions::Actor.ui(@user)

        Versions.save!(@target, actor: actor) do
          WorkflowAggregateSave.new(@target, payload).validate!.apply!
        end

        saved = @target.steps.not_deleted.reorder(:position).to_a
        assert_equal 4, saved.size
        assert_equal [ nil, "summarise", "approve", "send_invoice" ], saved.map { |s| s.composite&.fetch("node") }
        assert_equal [ saved.first.id ], saved.second.depends_on_step_ids
        assert_equal "Summarise {{output:#{@upstream.id}:doc.json}}", saved.second.instructions
        assert_equal "{{output:#{saved.second.id}:summary.md}}", saved.last.kind_config["arguments"]["body"]
        assert_nil Actions::Governance.verify!(@target)
        assert_nil Actions::OutputReferences.verify!(@target)
      end

      test "the workflow check refuses what Save would refuse" do
        manifest = @manifest.deep_dup.merge("slug" => "heavy")
        manifest["graph"]["steps"][0]["required_agent_runtime"] = "claude_code"
        manifest["graph"]["steps"][0]["preferred_model"] = "Bad Model!"
        stamp_composite(manifest)

        error = assert_raises(Expander::Refused) { Expander.new(project: @project, ref: "local/heavy@1", workflow: @target).call }
        assert_match(/Summarise: Preferred model/, error.message)
      end

      test "a composite of twenty steps expands to twenty steps and never more" do
        keys = Array.new(Composite::MAX_STEPS) { |i| "s#{i}" }
        steps = keys.each_with_index.map { |key, i| { "key" => key, "kind" => "agent", "name" => key, "depends_on" => (i.zero? ? [] : [ keys[i - 1] ]) } }
        stamp_composite({ "kind" => "block", "namespace" => "local", "slug" => "big", "version" => 1, "label" => "Big",
                          "executor" => "composite", "ports" => { "in" => {}, "out" => {} }, "graph" => { "steps" => steps } })

        assert_equal 20, Expander.new(project: @project, ref: "local/big@1", workflow: @target).call.steps.size
      end

      test "a binding is data: graph keys in it are not rewritten and are refused" do
        assert_raises(Expander::Refused) { expand(bindings: { "fetch_invoice_invoice" => "see {{step:send_invoice}}" }) }
        assert_raises(Expander::Refused) { expand(bindings: { "fetch_invoice_invoice" => "{{output:summarise:summary.md}}" }) }
        assert_raises(Expander::Refused) { expand(bindings: { "fetch_invoice_invoice" => "{{output:new-1:summary.md}}" }, first_index: 1) }

        kept = expand(bindings: { "fetch_invoice_invoice" => "see {{output:#{@upstream.id}:doc.json}} and {{context:key}}" })
        assert_equal "Summarise see {{output:#{@upstream.id}:doc.json}} and {{context:key}}", kept.steps.first["instructions"]
      end

      test "an unbound port that only decides what the block waits on is refused, never silently dropped" do
        @summarise.update!(instructions: "Summarise it")
        stamp_composite(Extractor.new(workflow: @workflow, step_ids: [ @summarise.id, @approve.id, @send.id ], label: "Waiting").manifest.manifest)

        error = assert_raises(Expander::Refused) { Expander.new(project: @project, ref: "local/waiting@1").call }

        assert_match(/Bind fetch_invoice/, error.message)
      end

      test "an archived resource is dropped with a warning" do
        skill = create(:skill, scope: @project)
        manifest = @manifest.deep_dup.merge("slug" => "archived-skill")
        manifest["graph"]["steps"][0]["skill_ids"] = [ skill.id ]
        stamp_composite(manifest)
        skill.update_columns(archived_at: Time.current)

        result = Expander.new(project: @project, ref: "local/archived-skill@1").call

        assert_nil result.steps.first["skill_ids"].presence
        assert_equal 1, result.warnings.size
      end
    end
  end
end

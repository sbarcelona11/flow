# frozen_string_literal: true

require "test_helper"

module Actions
  class BlockCheckTest < ActiveSupport::TestCase
    SEARCH_SCHEMA = { "type" => "object",
                      "properties" => { "query" => { "type" => "string" }, "limit" => { "type" => "integer" }, "mode" => { "type" => "string" }, "extra" => { "type" => "string" } } }.freeze
    CONFIG = {
      "type" => "object",
      "properties" => {
        "query" => { "type" => "string", "pattern" => "^[a-z]+$", "x-type" => "aixle/string@1" },
        "limit" => { "type" => "integer", "minimum" => 1 },
        "mode" => { "type" => "string", "enum" => %w[fast slow] }
      },
      "required" => [ "query" ]
    }.freeze

    setup do
      @company = create(:company)
      @project = create(:project, company: @company, owner: create(:user, company: @company))
      @workflow = create(:workflow, scope: @project)
      @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", snapshot_tools: [
        { "name" => "search", "input_schema" => SEARCH_SCHEMA, "annotations" => { "readOnlyHint" => true } },
        { "name" => "other", "input_schema" => SEARCH_SCHEMA, "annotations" => { "readOnlyHint" => true } },
        { "name" => "delete_invoice", "annotations" => { "destructiveHint" => true } }
      ])
    end

    def define_block(slug = "lookup", operation: "search", config: CONFIG, effect: nil, executor: "action", uses: nil)
      uses ||= { "transport" => "mcp", "connection" => "Billing", "operation" => operation }
      manifest = { "kind" => "block", "namespace" => "acme", "slug" => slug, "version" => 1, "label" => slug, "executor" => executor,
                   "ports" => { "in" => {}, "out" => { "hits" => "aixle/string@1" } }, "config" => config }
      manifest.merge!(executor == "action" ? { "uses" => uses } : { "control" => "approval" })
      manifest["effect"] = effect if effect
      create(:module_definition, scope: @project, kind: "block", namespace: "acme", slug: slug, manifest: manifest)
    end

    def config_for(overrides = {})
      { "target" => "mcp_tool", "mcp_server_id" => @server.id, "tool" => "search", "effect" => "read",
        "arguments" => { "query" => "invoices" }, "block" => "acme/lookup@1" }.merge(overrides)
    end

    def build_action(config)
      build(:step, workflow: @workflow, kind: "action", agent: nil, kind_config: config)
    end

    def check(config) = with_feature(:workflow_action_steps, true, company: @company) { build_action(config).tap(&:valid?).errors[:base] }

    test "a step created from its block is accepted and keeps the block reference" do
      define_block
      with_feature(:workflow_action_steps, true, company: @company) do
        step = create(:step, workflow: @workflow, kind: "action", agent: nil, kind_config: config_for)

        assert_equal "acme/lookup@1", step.reload.kind_config["block"]
      end
    end

    test "a step without a block is checked as before" do
      with_feature(:workflow_action_steps, true, company: @company) do
        step = build_action(config_for.except("block"))

        assert step.valid?, step.errors.full_messages.to_sentence
      end
    end

    test "a block reference that is not a reference is a structural error" do
      with_feature(:workflow_action_steps, true, company: @company) do
        [ "nope", 5, "a" * 200 ].each do |value|
          step = build_action(config_for("block" => value))

          assert_not step.valid?
          assert_match(/block must be a module block reference/, step.errors[:kind_config].join)
        end
      end
    end

    test "a missing block is refused" do
      assert_includes check(config_for("block" => "acme/ghost@1")).join, "Unknown block acme/ghost@1"
    end

    test "an invalid block is refused with its reason" do
      define_block(config: { "type" => "object", "properties" => { "colour" => { "type" => "string" } } })

      assert_includes check(config_for), "The block acme/lookup@1 is invalid: config property colour is not an argument of search"
    end

    test "an unresolved block is refused" do
      create(:module_definition, :capability, scope: @project, namespace: "acme", slug: "invoice")
      define_block(uses: { "capability" => "acme/invoice@1" })

      assert_match(/The block acme\/lookup@1 is unresolved/, check(config_for).first)
    end

    test "a block that is not an action block is refused" do
      define_block(executor: "control")

      assert_equal [ "The block acme/lookup@1 is not an action block." ], check(config_for)
    end

    test "a different target than the block's is refused" do
      define_block

      assert_equal [ "The action's tool is not the one block acme/lookup@1 uses." ], check(config_for("tool" => "other"))
    end

    test "arguments outside the block's config are refused" do
      define_block

      assert_includes check(config_for("arguments" => { "query" => "a", "extra" => "x" })).join, "extra is not one of its settings"
    end

    test "arguments are held to the block's config schema" do
      define_block

      assert_match(/Arguments don't match block/, check(config_for("arguments" => { "query" => "a", "limit" => 0 })).join)
      assert_match(/Arguments don't match block/, check(config_for("arguments" => { "query" => "a", "mode" => "medium" })).join)
      assert_match(/Arguments don't match block/, check(config_for("arguments" => { "query" => "UPPER" })).join)
      assert_match(/Arguments don't match block/, check(config_for("arguments" => { "limit" => 3 })).join)
      assert_empty check(config_for("arguments" => { "query" => "abc", "limit" => 3, "mode" => "fast" }))
    end

    test "a placeholder skips the check of its own value only" do
      define_block

      assert_empty check(config_for("arguments" => { "query" => "{{output:12:hits.json}}", "limit" => "{{context:n}}" }))
      assert_match(/Arguments don't match block/,
                   check(config_for("arguments" => { "query" => "{{context:q}}", "mode" => "medium" })).join)
      assert_match(/Arguments don't match block/, check(config_for("arguments" => { "limit" => "{{context:n}}" })).join)
    end

    test "a pattern that times out is an error, not an exception" do
      define_block

      Modules::Registry.builtin_types
      real = JSONSchemer.method(:schema)
      slow = ->(schema, **options) { schema == CONFIG ? raise(Regexp::TimeoutError) : real.call(schema, **options) }
      JSONSchemer.stub(:schema, slow) do
        assert_match(/took too long to check/, BlockCheck.errors(@project, config_for).join)
      end
    end

    test "an effect below the block's is refused and the operation's floor still applies" do
      define_block(effect: "write")
      define_block("deleter", operation: "delete_invoice", config: { "type" => "object" })

      assert_equal [ "The effect can't be lower than the block's own (write)." ], check(config_for("effect" => "read"))
      assert_empty check(config_for("effect" => "write"))
      assert_equal [ "The effect can't be lower than the tool's own (irreversible)." ],
                   check(config_for("tool" => "delete_invoice", "block" => "acme/deleter@1", "arguments" => {}, "effect" => "write"))
    end

    test "a stored step keeps saving when only its name changes after the block disappears" do
      definition = define_block
      with_feature(:workflow_action_steps, true, company: @company) do
        step = create(:step, workflow: @workflow, kind: "action", agent: nil, kind_config: config_for)
        definition.archive!

        assert step.update(name: "Renamed")
      end
    end
  end
end

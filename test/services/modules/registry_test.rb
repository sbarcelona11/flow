# frozen_string_literal: true

require "test_helper"

module Modules
  class RegistryTest < ActiveSupport::TestCase
    setup do
      @project = create(:project, :standalone)
      @registry = -> { Registry.new(@project) }
    end

    def define(kind, slug, version: 1, namespace: "acme", project: @project, **fields)
      manifest = { "kind" => kind, "namespace" => namespace, "slug" => slug, "version" => version, "label" => slug.titleize }.merge(fields.stringify_keys)
      create(:module_definition, scope: project, kind: kind, namespace: namespace, slug: slug, version: version, manifest: manifest)
    end

    def action_block(slug, uses:, effect: nil, ports: { "in" => { "amount" => "aixle/money@1" }, "out" => {} })
      define("block", slug, executor: "action", uses: uses, ports: ports, **{ effect: effect }.compact)
    end

    def rest_operation(effect:)
      connector = create(:api_connector, scope: @project, name: "billing")
      create(:api_operation, api_connector: connector, name: "create_invoice", effect: effect)
    end

    test "built-in types load and cannot be overridden" do
      keys = @registry.call.types.map(&:key)

      %w[string number integer boolean date datetime money period file list record].each do |slug|
        assert_includes keys, "aixle/#{slug}@1"
      end
      assert @registry.call.type("aixle/money@1").builtin
      assert_equal "valid", @registry.call.type("aixle/money@1").status

      assert_not build(:module_definition, scope: @project, namespace: "aixle", slug: "money").valid?

      definition = define("type", "money", schema: { "type" => "object" })
      definition.update_columns(namespace: "aixle", manifest: definition.manifest.merge("namespace" => "aixle"))
      assert_equal "Money", @registry.call.type("aixle/money@1").label
    end

    test "resolves types and capabilities of this project" do
      define("type", "sku", schema: { "type" => "string" })
      define("capability", "invoice", input: "acme/sku@1", output: "aixle/file@1")

      assert_equal "acme/sku@1", @registry.call.type("acme/sku@1").key
      assert_equal "valid", @registry.call.capability("acme/invoice@1").status
    end

    test "unknown version fails naming it" do
      define("type", "sku", schema: { "type" => "string" })

      error = assert_raises(Registry::Unknown) { @registry.call.type("acme/sku@2") }
      assert_includes error.message, "acme/sku@2"
      assert_includes error.message, "available versions are 1"

      error = assert_raises(Registry::Unknown) { @registry.call.type("acme/sku") }
      assert_includes error.message, "acme/sku"
      assert_includes error.message, "version is required"

      assert_raises(Registry::Unknown) { @registry.call.block("acme/nothing@1") }
      assert_raises(Registry::Unknown) { @registry.call.capability("aixle/money@1") }
    end

    test "a block listing a missing version is invalid and names the reference" do
      define("type", "sku", schema: { "type" => "string" })
      block = define("block", "pick", executor: "control", control: "approval",
                                      ports: { "in" => { "sku" => "acme/sku@2" }, "out" => {} })

      entry = @registry.call.blocks.find { |candidate| candidate.key == block.parsed_manifest.key }

      assert_equal "invalid", entry.status
      assert_includes entry.reason, "acme/sku@2"
    end

    test "refuses a type reference to another project's module" do
      other = create(:project, :standalone)
      define("type", "secret-shape", project: other, schema: { "type" => "string" })
      define("block", "peek", executor: "control", control: "wait",
                              ports: { "in" => { "x" => "acme/secret-shape@1" }, "out" => {} })

      entry = @registry.call.blocks.first

      assert_equal "invalid", entry.status
      assert_includes entry.reason, "acme/secret-shape@1"
      assert_raises(Registry::Unknown) { @registry.call.type("acme/secret-shape@1") }
    end

    test "lists palette blocks with their fields" do
      define("block", "approve", executor: "control", control: "approval", config: { "type" => "object" },
                                 ports: { "in" => { "subject" => "aixle/string@1" }, "out" => { "decision" => "aixle/boolean@1" } })

      entry = @registry.call.blocks.sole

      assert_equal "acme/approve@1", entry.key
      assert_equal "Approve", entry.label
      assert_equal "control", entry.executor
      assert_equal({ "type" => "object" }, entry.config)
      assert_equal "valid", entry.status
      assert_nil entry.reason
      assert_equal "aixle/boolean@1", entry.ports.dig("out", "decision")
    end

    test "disabled and archived modules are not resolved" do
      disabled = define("type", "off", schema: { "type" => "string" })
      disabled.update!(enabled: false)
      define("type", "gone", schema: { "type" => "string" }).archive!

      assert_raises(Registry::Unknown) { @registry.call.type("acme/off@1") }
      assert_raises(Registry::Unknown) { @registry.call.type("acme/gone@1") }
    end

    test "a block resolved against the live catalog is valid" do
      rest_operation(effect: "write")
      block = action_block("invoice", uses: { "transport" => "rest", "connection" => "billing", "operation" => "create_invoice" },
                                      effect: "send")

      entry = @registry.call.block(block.parsed_manifest.key)

      assert_equal "valid", entry.status, entry.reason
    end

    test "refuses an effect below its operation's" do
      rest_operation(effect: "send")
      action_block("invoice", uses: { "transport" => "rest", "connection" => "billing", "operation" => "create_invoice" },
                              effect: "read")

      entry = @registry.call.blocks.sole

      assert_equal "invalid", entry.status
      assert_match(/effect read is below the operation's own effect send/, entry.reason)
    end

    test "a block over an unknown operation or transport is invalid" do
      rest_operation(effect: "read")
      action_block("a", uses: { "transport" => "rest", "connection" => "billing", "operation" => "nope" })
      action_block("b", uses: { "transport" => "carrier_pigeon", "connection" => "billing", "operation" => "x" })

      reasons = @registry.call.blocks.to_h { |entry| [ entry.key, entry.reason ] }

      assert_match(/operation "nope"/, reasons["acme/a@1"])
      assert_match(/transport "carrier_pigeon"/, reasons["acme/b@1"])
    end

    test "block with uses.capability registers as unresolved" do
      define("capability", "invoice", input: "aixle/money@1", output: "aixle/file@1")
      define("block", "bill", executor: "action", uses: { "capability" => "acme/invoice@1" },
                              ports: { "in" => { "amount" => "aixle/money@1" }, "out" => { "receipt" => "aixle/file@1" } })

      entry = @registry.call.blocks.sole

      assert_equal "unresolved", entry.status
      assert entry.unresolved
    end

    test "a block using an unknown capability is invalid" do
      define("block", "bill", executor: "action", uses: { "capability" => "acme/invoice@1" }, ports: { "in" => {}, "out" => {} })

      entry = @registry.call.blocks.sole

      assert_equal "invalid", entry.status
      assert_includes entry.reason, "acme/invoice@1"
    end

    test "stored rows that no longer parse are listed as invalid with their reason" do
      definition = define("type", "sku", schema: { "type" => "string" })
      definition.update_columns(manifest: definition.manifest.merge("schema" => { "$ref" => "x" }))

      entry = @registry.call.types.find { |candidate| candidate.key == "acme/sku@1" }

      assert_equal "invalid", entry.status
      assert_match(/unsupported keyword/, entry.reason)
      assert_equal "acme/sku@1", entry.label
      assert_equal "invalid", @registry.call.type("acme/sku@1").status
    end

    test "resolving many blocks does not query per distinct connection name" do
      rest_operation(effect: "read")
      counter = lambda do |count, prefix|
        count.times do |n|
          action_block("#{prefix}#{n}", uses: { "transport" => "rest", "connection" => "conn#{n}", "operation" => "x" })
        end
        queries = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries += 1 unless payload[:name] == "SCHEMA" }
        @registry.call.blocks
        queries
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      few = counter.call(3, "a")
      many = counter.call(40, "b")

      assert_equal few, many
    end

    test "nested typed fields resolve through x-type" do
      define("type", "sku", schema: { "type" => "string" })
      define("type", "line", schema: { "type" => "object", "properties" => { "sku" => { "x-type" => "acme/sku@1" } } })

      assert_equal "valid", @registry.call.type("acme/line@1").status
    end

    test "a type referencing an unknown type is invalid in the registry" do
      definition = define("type", "line", schema: { "type" => "object" })
      definition.update_columns(manifest: definition.manifest.merge("schema" => { "properties" => { "a" => { "x-type" => "acme/missing@1" } } }))

      entry = @registry.call.type("acme/line@1")

      assert_equal "invalid", entry.status
      assert_includes entry.reason, "acme/missing@1"
    end

    test "a reference cycle between types is refused" do
      a = define("type", "a", schema: { "type" => "string" })
      define("type", "b", schema: { "type" => "object", "properties" => { "a" => { "x-type" => "acme/a@1" } } })

      a.manifest = a.manifest.merge("schema" => { "type" => "object", "properties" => { "b" => { "x-type" => "acme/b@1" } } })

      assert_not a.valid?
      assert_match(/reference cycle acme\/a@1 -> acme\/b@1 -> acme\/a@1/, a.errors[:manifest].first)

      a.save!(validate: false)
      assert_equal "invalid", @registry.call.type("acme/a@1").status
      assert_equal "invalid", @registry.call.type("acme/b@1").status
    end

    test "a type refusing to nest deeper than the limit" do
      define("type", "t0", schema: { "type" => "string" })
      (1...Registry::MAX_TYPE_DEPTH).each do |n|
        define("type", "t#{n}", schema: { "properties" => { "p" => { "x-type" => "acme/t#{n - 1}@1" } } })
      end
      too_deep = build(:module_definition, scope: @project, slug: "t#{Registry::MAX_TYPE_DEPTH}",
                                           manifest: { "kind" => "type", "namespace" => "acme", "slug" => "t#{Registry::MAX_TYPE_DEPTH}", "version" => 1, "label" => "T",
                                                       "schema" => { "properties" => { "p" => { "x-type" => "acme/t#{Registry::MAX_TYPE_DEPTH - 1}@1" } } } })
      assert_not too_deep.valid?
      too_deep.save!(validate: false)

      assert_equal "valid", @registry.call.type("acme/t#{Registry::MAX_TYPE_DEPTH - 1}@1").status
      assert_equal "invalid", @registry.call.type("acme/t#{Registry::MAX_TYPE_DEPTH}@1").status
    end
  end
end

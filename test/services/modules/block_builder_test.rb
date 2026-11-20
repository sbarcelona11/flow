# frozen_string_literal: true

require "test_helper"

module Modules
  class BlockBuilderTest < ActiveSupport::TestCase
    setup do
      @project = create(:project, :standalone)
      @connector = create(:api_connector, scope: @project, name: "billing")
      @operation = create(:api_operation, api_connector: @connector, name: "get_invoice", http_method: "GET", path: "/invoices/{id}",
                                          summary: "Get an invoice", input_schema: schema)
    end

    def schema(query: { "expand" => { "type" => "string", "description" => "Fields to expand" } })
      { "type" => "object",
        "properties" => {
          "path" => { "type" => "object", "properties" => { "id" => { "type" => "string" } }, "required" => [ "id" ] },
          "query" => { "type" => "object", "properties" => query }
        } }
    end

    def build(**options)
      BlockBuilder.from_operation(project: @project, operation: @operation, label: "Get invoice", **options)
    end

    def store(result)
      create(:module_definition, scope: @project, kind: "block", namespace: result.manifest["namespace"],
                                 slug: result.manifest["slug"], version: result.manifest["version"], manifest: result.manifest)
    end

    test "builds a manifest that parses and resolves as a valid block" do
      result = build

      assert_equal Manifest.from_hash(result.manifest).to_h, result.manifest
      assert_equal "local/get-invoice@1", Manifest.from_hash(result.manifest).key
      assert_equal({ "transport" => "rest", "connection" => "billing", "operation" => "get_invoice" }, result.manifest["uses"])
      assert_equal({ "in" => {}, "out" => { "result" => "aixle/record@1" } }, result.manifest["ports"])
      assert_equal %w[id], result.manifest.dig("config", "properties", "path", "properties").keys
      assert_equal %w[expand], result.manifest.dig("config", "properties", "query", "properties").keys
      assert_empty result.warnings

      store(result)
      entry = Registry.new(@project).block("local/get-invoice@1")
      assert_equal "valid", entry.status, entry.reason
      assert_equal "read", entry.effect
    end

    test "settings choose which arguments the block exposes, keeping the grouping" do
      result = build(settings: %w[expand])

      assert_nil result.manifest.dig("config", "properties", "path")
      assert_equal %w[expand], result.manifest.dig("config", "properties", "query", "properties").keys
      store(result)
      assert_equal "valid", Registry.new(@project).block("local/get-invoice@1").status
    end

    test "an unknown setting is refused" do
      error = assert_raises(ArgumentError) { build(settings: %w[nope]) }
      assert_match(/nope/, error.message)
    end

    test "an operation without arguments yields a block without config" do
      @operation.update!(path: "/invoices", input_schema: {})

      assert_not build.manifest.key?("config")
    end

    test "a catastrophic pattern is dropped with a warning and the property stays" do
      @operation.update!(input_schema: schema(query: { "code" => { "type" => "string", "pattern" => "^(.)\\1+$", "description" => "Code" } }))
      result = build

      code = result.manifest.dig("config", "properties", "query", "properties", "code")
      assert_equal "string", code["type"]
      assert_not code.key?("pattern")
      assert_equal 1, result.warnings.size
      assert_match(/code/, result.warnings.first)
    end

    test "format regex, references and credential-looking defaults are dropped with one warning per property" do
      @operation.update!(input_schema: schema(query: {
                           "rx" => { "type" => "string", "format" => "regex" },
                           "token" => { "type" => "string", "default" => "sk-live-abcdefghijklmnop" },
                           "ok" => { "type" => "string" }
                         }))
      result = build

      props = result.manifest.dig("config", "properties", "query", "properties")
      assert_not props["rx"].key?("format")
      assert_not props["token"].key?("default")
      assert_equal 2, result.warnings.size
      store(result)
      assert_equal "valid", Registry.new(@project).block("local/get-invoice@1").status
    end

    test "an effect below the operation's is raised and a higher one is kept" do
      @operation.update!(http_method: "POST", effect: "write")

      assert_equal "write", build(effect: "read").manifest["effect"]
      assert_equal "send", build(effect: "send").manifest["effect"]
      assert_equal "write", build.manifest["effect"]
    end

    test "the slug follows the operation name and the version is the next free one" do
      store(build)
      assert_equal 2, build.manifest["version"]
      assert_equal "get-invoice", build.manifest["slug"]
    end

    test "a slug already used for another operation gets the connector's name in front" do
      store(build)
      other = create(:api_connector, scope: @project, name: "Other API")
      same_name = create(:api_operation, api_connector: other, name: "get_invoice")
      result = BlockBuilder.from_operation(project: @project, operation: same_name, label: "Other")

      assert_equal "other-api-get-invoice", result.manifest["slug"]
      assert_equal 1, result.manifest["version"]
    end

    test "namespace is local unless given, and aixle is refused by the manifest rules" do
      assert_equal "local", build.manifest["namespace"]
      assert_equal "acme", build(namespace: "acme").manifest["namespace"]
      assert_raises(ArgumentError) { build(namespace: "aixle") }
    end

    test "an operation of another project is refused" do
      foreign = create(:api_operation)

      assert_raises(ArgumentError) { BlockBuilder.from_operation(project: @project, operation: foreign, label: "x") }
    end

    test "a blank or oversized label is the manifest's error" do
      assert_raises(Manifest::Invalid) { build(label: "") }
      assert_raises(Manifest::Invalid) { build(label: "x" * 201) }
    end

    test "description falls back to the operation's summary and loses control characters" do
      assert_equal "Get an invoice", build.manifest["description"]
      assert_equal "Hello world", build(description: "Hello\u0000 world").manifest["description"]
    end
  end
end

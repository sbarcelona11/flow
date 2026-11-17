# frozen_string_literal: true

require "test_helper"

module Rest
  class OpenapiImporterTest < ActiveSupport::TestCase
    def document(paths, components: {}, servers: [ { "url" => "https://api.example.com" } ], version: "3.0.3")
      { "openapi" => version, "info" => { "title" => "t", "version" => "1" }, "servers" => servers,
        "paths" => paths, "components" => components }.to_json
    end

    def get_operation(extra = {})
      { "get" => { "responses" => { "200" => { "description" => "ok" } } }.merge(extra) }
    end

    def assert_saves(draft)
      connector = create(:api_connector)
      operation = ApiOperation.new(api_connector: connector, name: draft.name, path: draft.path, effect: draft.effect,
                                   input_schema: draft.input_schema, summary: draft.summary,
                                   description: draft.description).tap { |op| op[:method] = draft.method }
      assert operation.valid?, "#{draft.name}: #{operation.errors.full_messages.to_sentence}"
    end

    def import_error(&)
      assert_raises(ImportError, &).message
    end

    test "imports a petstore 3.0 document" do
      result = OpenapiImporter.from_text(file_fixture("openapi/petstore.json").read)

      assert_equal "https://petstore.example.com/v1", result.base_url
      by_name = result.operations.index_by(&:name)
      assert_equal %w[create_pets delete_pets_pet_id list_pets show_pet_by_id upload_photo], by_name.keys.sort

      list = by_name["list_pets"]
      assert_equal [ "GET", "/pets", "read", "List all pets" ], [ list.method, list.path, list.effect, list.summary ]
      assert_equal({ "type" => "integer", "format" => "int32", "description" => "How many items to return" },
                   list.input_schema.dig("properties", "query", "properties", "limit"))

      show = by_name["show_pet_by_id"]
      assert_equal "/pets/{petId}", show.path
      assert_equal [ "petId" ], show.input_schema.dig("properties", "path", "required")

      create = by_name["create_pets"]
      assert_equal [ "POST", "write" ], [ create.method, create.effect ]
      assert_equal [ "name" ], create.input_schema.dig("properties", "body", "required")
      assert_includes create.input_schema["required"], "body"

      upload = by_name["upload_photo"]
      assert_nil upload.input_schema.dig("properties", "body")
      assert_equal "write", by_name["delete_pets_pet_id"].effect

      assert(result.warnings.any? { |w| w.include?("X-Request-Id") && w.include?("header") })
      assert(result.warnings.any? { |w| w.include?("PUT /pets/{petId}/photo") && w.include?("image/png") })
      result.operations.each { |draft| assert_saves(draft) }
    end

    test "imports YAML" do
      result = OpenapiImporter.from_text(file_fixture("openapi/petstore.yaml").read)

      assert_equal %w[list_pets show_pet_by_id], result.operations.map(&:name)
      assert_equal "https://petstore.example.com/v1", result.base_url
      result.operations.each { |draft| assert_saves(draft) }
    end

    test "resolves local refs and stops on a cycle" do
      components = { "schemas" => {
        "Node" => { "type" => "object", "properties" => { "label" => { "$ref" => "#/components/schemas/Label" },
                                                          "child" => { "$ref" => "#/components/schemas/Node" } } },
        "Label" => { "type" => "string", "maxLength" => 40 }
      } }
      paths = { "/nodes" => { "post" => {
        "operationId" => "createNode",
        "requestBody" => { "content" => { "application/json" => { "schema" => { "$ref" => "#/components/schemas/Node" } } } },
        "responses" => {}
      } } }

      result = OpenapiImporter.from_text(document(paths, components: components))
      body = result.operations.first.input_schema.dig("properties", "body")

      assert_equal({ "type" => "string", "maxLength" => 40 }, body.dig("properties", "label"))
      assert_equal({}, body.dig("properties", "child"))
      assert(result.warnings.any? { |w| w.include?("#/components/schemas/Node") })
      assert_not_includes result.operations.first.input_schema.to_json, "$ref"
      assert_saves(result.operations.first)
    end

    test "refuses a ref explosion" do
      schemas = { "L0" => { "type" => "string" } }
      (1..40).each do |i|
        schemas["L#{i}"] = { "type" => "object", "properties" => { "a" => { "$ref" => "#/components/schemas/L#{i - 1}" },
                                                                   "b" => { "$ref" => "#/components/schemas/L#{i - 1}" } } }
      end
      paths = { "/x" => { "post" => { "requestBody" => { "content" => { "application/json" =>
        { "schema" => { "$ref" => "#/components/schemas/L40" } } } }, "responses" => {} } } }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      message = import_error { OpenapiImporter.from_text(document(paths, components: { "schemas" => schemas })) }

      assert_equal "This document expands to more than the import limit. Import a smaller part of the document.", message
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    end

    def assert_quick(limit: 2)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = begin
        yield
      rescue ImportError
        nil
      end
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, limit
      assert_operator result.warnings.size, :<=, 101 if result
      result
    end

    test "many parameters on one operation finish quickly" do
      parameters = (1..30_000).map { |i| { "name" => "q#{i}", "in" => "query", "required" => true } }

      result = assert_quick { OpenapiImporter.from_text(document({ "/x" => get_operation("parameters" => parameters) })) }

      assert(result.warnings.any? { |w| w.include?("GET /x") && w.include?("200 parameters") })
      assert_empty result.operations
    end

    test "a path item referenced many times finishes quickly with capped warnings" do
      headers = (1..20_000).map { |i| { "name" => "h#{i}", "in" => "header" } }
      big = { "parameters" => headers, "get" => { "responses" => {} } }
      paths = (1..99).to_h { |i| [ "/p#{i}", { "$ref" => "#/components/pathItems/Big" } ] }
      paths["/many/{a}"] = get_operation("parameters" => (1..150).map { |i| { "name" => "h#{i}", "in" => "header" } })

      result = assert_quick do
        OpenapiImporter.from_text(document(paths, components: { "pathItems" => { "Big" => big } }, version: "3.1.0"))
      end

      assert_equal 101, result.warnings.size
      assert_match(/… and \d+ more warnings\./, result.warnings.last)
    end

    test "a server URL with a user name or password is never echoed" do
      probes = [
        [ { "url" => "http://user:SECRETPW@api.example.com" } ],
        [ { "url" => "https://{h}/v1", "variables" => { "h" => { "default" => "user:SECRETPW@api.example.com" } } } ],
        [ { "url" => "user:SECRETPW@api.example.com/v1" } ],
        [ { "url" => "https:\\\\user:SECRETPW@api.example.com" } ]
      ]

      probes.each do |servers|
        result = OpenapiImporter.from_text(document({ "/x" => get_operation }, servers: servers))

        assert_nil result.base_url, servers.inspect
        assert_equal [ "The first server URL includes a user name or password; it was not used." ], result.warnings
        assert_not_includes result.to_json, "SECRETPW"
      end
    end

    test "unquoted YAML dates import, non-finite numbers are dropped and a non-string $ref is not a reference" do
      yaml = <<~YAML
        openapi: 3.0.0
        info: { title: t, version: 1, x-released: 2020-01-01 }
        paths:
          /x:
            get:
              operationId: x
              parameters:
                - name: since
                  in: query
                  schema: { type: string, example: 2020-01-01, maximum: .inf, minimum: 1 }
                - name: odd
                  in: query
                  schema: { type: string, $ref: 5 }
              responses: {}
      YAML

      result = OpenapiImporter.from_text(yaml)
      query = result.operations.sole.input_schema.dig("properties", "query", "properties")

      assert_equal({ "type" => "string", "example" => "2020-01-01", "minimum" => 1 }, query["since"])
      assert_equal({ "type" => "string" }, query["odd"])
      assert(result.warnings.any? { |w| w.include?("maximum") && w.include?("finite") })
      assert_saves(result.operations.sole)
    end

    test "refuses a document over 2 MB" do
      message = import_error { OpenapiImporter.from_text("{" + (" " * 2.megabytes) + "}") }

      assert_match(/2 MB/, message)
    end

    test "refuses YAML aliases" do
      bomb = <<~YAML
        openapi: 3.0.0
        a: &a ["x", "x", "x", "x", "x", "x", "x", "x", "x"]
        b: &b [*a, *a, *a, *a, *a, *a, *a, *a, *a]
        c: &c [*b, *b, *b, *b, *b, *b, *b, *b, *b]
        paths: {}
      YAML

      assert_match(/alias/i, import_error { OpenapiImporter.from_text(bomb) })
    end

    test "refuses malformed, unsupported or oversized documents with a clear message" do
      assert_match(/not valid JSON or YAML/, import_error { OpenapiImporter.from_text("{\"openapi\": ") })
      assert_match(/not valid JSON or YAML/, import_error { OpenapiImporter.from_text("openapi: [1, 2") })
      assert_match(/OpenAPI 3\.0 and 3\.1/, import_error { OpenapiImporter.from_text({ "swagger" => "2.0" }.to_json) })
      assert_match(/OpenAPI 3\.0 and 3\.1/, import_error { OpenapiImporter.from_text("just a string") })
      assert_match(/nests too deeply/, import_error { OpenapiImporter.from_text(("[" * 5_000) + ("]" * 5_000)) })
      assert_match(/nests too deeply/, import_error { OpenapiImporter.from_text(("- " * 5_000) + "x") })
      assert_match(/YAML type/, import_error { OpenapiImporter.from_text("openapi: 3.0.0\nx: !ruby/object:Object {}\n") })

      many = (1..501).to_h { |i| [ "/r#{i}", get_operation ] }
      assert_match(/501 operations.*500/, import_error { OpenapiImporter.from_text(document(many)) })
    end

    test "refuses a remote $ref" do
      paths = { "/x" => { "get" => { "parameters" => [ { "$ref" => "https://evil.example/params.json#/limit" } ],
                                     "responses" => {} } } }

      message = import_error { OpenapiImporter.from_text(document(paths)) }

      assert_match(%r{https://evil\.example/params\.json#/limit}, message)
      assert_match(/inside the document/, message)
    end

    test "an http server URL becomes a warning" do
      result = OpenapiImporter.from_text(document({ "/x" => get_operation }, servers: [ { "url" => "http://api.example.com/v2" } ]))

      assert_nil result.base_url
      assert_equal [ "The first server URL is not an https URL; enter the base URL yourself." ], result.warnings
    end

    test "server variables and a relative server URL" do
      servers = [ { "url" => "https://{region}.example.com/{version}",
                    "variables" => { "region" => { "default" => "eu" }, "version" => { "default" => "v3" } } } ]
      assert_equal "https://eu.example.com/v3", OpenapiImporter.from_text(document({ "/x" => get_operation }, servers: servers)).base_url

      relative = OpenapiImporter.from_text(document({ "/x" => get_operation }, servers: [ { "url" => "/api" } ]))
      assert_nil relative.base_url
      assert_includes relative.warnings, "The first server URL is not an https URL; enter the base URL yourself."
    end

    test "names are snake_case, unique and fall back to method and path" do
      paths = {
        "/a" => get_operation("operationId" => "Get-Thing.ByID"),
        "/b" => get_operation("operationId" => "get_thing_by_id"),
        "/c" => get_operation("operationId" => "getThingByID"),
        "/v1/{org-name}/items" => get_operation,
        "/v1/{org}/items" => get_operation("operationId" => "9lives#{'x' * 80}")
      }
      result = OpenapiImporter.from_text(document(paths))

      assert_equal %w[get_thing_by_id get_thing_by_id_2 get_thing_by_id_3], result.operations.first(3).map(&:name)
      long = result.operations.last
      assert_match ApiOperation::NAME_FORMAT, long.name
      assert_equal "/v1/{org}/items", long.path
      assert(result.warnings.any? { |w| w.include?("GET /v1/{org-name}/items") })
      result.operations.each { |draft| assert_saves(draft) }
    end

    test "path placeholders become required string path properties" do
      result = OpenapiImporter.from_text(document({ "/things/{id}/parts/{part}" => get_operation(
        "operationId" => "part", "parameters" => [ { "name" => "part", "in" => "path", "required" => true } ]
      ) }))
      path = result.operations.first.input_schema.dig("properties", "path")

      assert_equal({ "type" => "string" }, path.dig("properties", "id"))
      assert_equal({ "type" => "string" }, path.dig("properties", "part"))
      assert_equal %w[id part], path["required"].sort
      assert_saves(result.operations.first)
    end

    test "descriptions are truncated plain strings and too-large schemas are skipped" do
      huge = { "type" => "object", "properties" => (1..3_000).to_h { |i| [ "field_#{i}", { "type" => "string" } ] } }
      paths = {
        "/small" => get_operation("operationId" => "small", "description" => "<script>#{'d' * 5_000}",
                                  "summary" => { "nested" => "object" }),
        "/huge" => { "post" => { "operationId" => "huge", "responses" => {},
                                 "requestBody" => { "content" => { "application/json" => { "schema" => huge } } } } }
      }
      result = OpenapiImporter.from_text(document(paths))

      small = result.operations.sole
      assert_equal 2_000, small.description.length
      assert small.description.start_with?("<script>")
      assert_nil small.summary
      assert(result.warnings.any? { |w| w.include?("POST /huge") })
    end

    test "fetches a spec over SafeHttp and refuses a private address" do
      resolve_hosts_publicly!
      stub_request(:get, "https://specs.example.com/openapi.json")
        .with(headers: { "Accept-Encoding" => "identity" })
        .to_return(status: 200, body: file_fixture("openapi/petstore.json").read)

      result = OpenapiImporter.from_url("https://specs.example.com/openapi.json")
      assert_equal 5, result.operations.size

      assert_match(/private/, import_error { OpenapiImporter.from_url("https://10.0.0.5/openapi.json") })
      assert_match(/https/, import_error { OpenapiImporter.from_url("http://specs.example.com/openapi.json") })
      assert_match(/internal/, import_error { OpenapiImporter.from_url("https://localhost/openapi.json") })
    end

    test "a fetched spec does not follow redirects and is capped" do
      resolve_hosts_publicly!
      stub_request(:get, "https://specs.example.com/moved").to_return(status: 302, headers: { "Location" => "https://10.0.0.5/" })
      stub_request(:get, "https://specs.example.com/big").to_return(status: 200, body: "x" * (2.megabytes + 1))
      stub_request(:get, "https://specs.example.com/missing").to_return(status: 404)
      stub_request(:get, "https://specs.example.com/slow").to_timeout

      assert_match(/302/, import_error { OpenapiImporter.from_url("https://specs.example.com/moved") })
      assert_match(/2 MB/, import_error { OpenapiImporter.from_url("https://specs.example.com/big") })
      assert_match(/404/, import_error { OpenapiImporter.from_url("https://specs.example.com/missing") })
      assert_match(/could not be fetched/, import_error { OpenapiImporter.from_url("https://specs.example.com/slow") })
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Rest
  class CurlImporterTest < ActiveSupport::TestCase
    TOKEN = "sk-live-9f8e7d6c5b4a"

    def assert_saves(draft)
      operation = ApiOperation.new(api_connector: create(:api_connector), name: draft.name, path: draft.path,
                                   effect: draft.effect, origin: "web", reviewed_at: Time.current, input_schema: draft.input_schema).tap { |op| op.http_method = draft.http_method }
      assert operation.valid?, operation.errors.full_messages.to_sentence
    end

    test "cURL with a bearer token drops the token and warns" do
      command = <<~CURL
        curl -sS https://api.example.com/v1/things?limit=5&api_key=#{TOKEN} \\
          -H 'Authorization: Bearer #{TOKEN}' \\
          -H "x-service-token: #{TOKEN}" \\
          --header 'Cookie: session=#{TOKEN}' \\
          -H 'Accept: application/json' \\
          -u admin:#{TOKEN}
      CURL

      result = CurlImporter.parse(command)
      draft = result.operations.sole

      assert_equal "https://api.example.com", result.base_url
      assert_equal [ "GET", "/v1/things", "read", "get_v1_things" ], [ draft.http_method, draft.path, draft.effect, draft.name ]
      assert_equal [ "limit" ], draft.input_schema.dig("properties", "query", "properties").keys
      %w[Authorization x-service-token Cookie api_key].each do |name|
        assert(result.warnings.any? { |w| w.include?("Choose a Config Item for #{name} on the connector") }, name)
      end
      assert(result.warnings.any? { |w| w.include?("-u") && w.include?("basic") })
      assert_not_includes result.to_json, TOKEN
      assert_not_includes result.inspect, TOKEN
      assert_saves(draft)
    end

    test "cURL with -d JSON maps body properties" do
      command = %(curl -X POST --url https://api.example.com/v1/orders -H 'Content-Type: application/json' ) +
                %(--data-raw '{"name":"Ada","count":2,"ratio":0.5,"paid":false,"address":{"city":"Paris"},"tags":["a"],"password":"#{TOKEN}"}')

      result = CurlImporter.parse(command)
      draft = result.operations.sole
      body = draft.input_schema.dig("properties", "body")

      assert_equal [ "POST", "/v1/orders", "write" ], [ draft.http_method, draft.path, draft.effect ]
      assert_equal({ "name" => { "type" => "string" }, "count" => { "type" => "integer" }, "ratio" => { "type" => "number" },
                     "paid" => { "type" => "boolean" },
                     "address" => { "type" => "object", "properties" => { "city" => { "type" => "string" } } },
                     "tags" => { "type" => "array", "items" => { "type" => "string" } },
                     "password" => { "type" => "string" } }, body["properties"])
      assert_equal "object", body["type"]
      assert_not_includes result.to_json, TOKEN
      assert_not_includes result.to_json, "Ada"
      assert_saves(draft)
    end

    test "data without -X makes a POST and -G moves it to the query" do
      assert_equal "POST", CurlImporter.parse(%(curl https://api.example.com/x -d '{"a":1}')).operations.sole.http_method

      result = CurlImporter.parse("curl -G https://api.example.com/search -d q=books -d token=#{TOKEN}")
      draft = result.operations.sole
      assert_equal "GET", draft.http_method
      assert_equal [ "q" ], draft.input_schema.dig("properties", "query", "properties").keys
      assert(result.warnings.any? { |w| w.include?("token") })
      assert_not_includes result.to_json, TOKEN
    end

    test "a header without a name is reported without its value" do
      result = CurlImporter.parse("curl https://api.example.com/x -H '#{TOKEN}' -H 'Bearer #{TOKEN}: x' -H 'X-Tenant: acme'")

      assert_includes result.warnings, "A header without a name was not imported."
      assert(result.warnings.any? { |w| w.include?("X-Tenant") })
      assert_not_includes result.to_json, TOKEN
    end

    test "credentials in the URL itself are stripped" do
      result = CurlImporter.parse("curl -XDELETE 'https://bob:#{TOKEN}@api.example.com/items/9#frag'")

      draft = result.operations.sole
      assert_equal [ "DELETE", "/items/9", "write" ], [ draft.http_method, draft.path, draft.effect ]
      assert_equal "https://api.example.com", result.base_url
      assert(result.warnings.any? { |w| w.include?("user name and password") })
      assert_not_includes result.to_json, TOKEN
    end

    test "an http URL and non-JSON data become warnings" do
      result = CurlImporter.parse("curl http://api.example.com:8080/form -d 'a=1&b=2' -H 'X-Trace: 1'")

      assert_nil result.base_url
      assert(result.warnings.any? { |w| w.include?("https") })
      assert(result.warnings.any? { |w| w.include?("JSON") })
      assert(result.warnings.any? { |w| w.include?("X-Trace") })
      assert_nil result.operations.sole.input_schema.dig("properties", "body")
    end

    test "values attached to ignored or unknown short options are never echoed" do
      command = "curl -Uproxy:PXSECRET -Ecert.pem:CERTPW -xhttp://u:XPW@proxy.example -ZZSECRET --frob=FROBSECRET " \
                "https://api.example.com/x"

      result = CurlImporter.parse(command)

      assert_equal "/x", result.operations.sole.path
      %w[PXSECRET CERTPW XPW ZSECRET FROBSECRET].each { |secret| assert_not_includes result.to_json, secret }
      assert(result.warnings.any? { |w| w.include?("-Z ") })
      assert(result.warnings.any? { |w| w.include?("--frob ") })
    end

    test "refuses what is not a usable cURL command" do
      { "wget https://api.example.com" => /curl/,
        "curl 'https://api.example.com" => /quote/,
        "curl -X TRACE https://api.example.com/x" => /TRACE/,
        "curl -H 'Accept: x'" => /URL/,
        "curl https://api.example.com/a/../b" => /path/,
        "curl #{'x' * 70_000}" => /too long/ }.each do |command, pattern|
        error = assert_raises(ImportError, command) { CurlImporter.parse(command) }
        assert_match pattern, error.message
      end
    end
  end
end

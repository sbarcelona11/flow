# frozen_string_literal: true

require "test_helper"

module Rest
  class RequestBuilderTest < ActiveSupport::TestCase
    setup do
      resolve_hosts_publicly!
      @project = create(:project, :standalone)
    end

    def connector(**attrs)
      create(:api_connector, { scope: @project, base_url: "https://api.example.com/v1" }.merge(attrs))
    end

    def operation(connector, verb: "GET", **attrs)
      FactoryBot.build(:api_operation, :with_path_param, { api_connector: connector, effect: verb == "GET" ? "read" : "write" }.merge(attrs))
                .tap { |op| op[:method] = verb }.tap(&:save!)
    end

    def build_request(operation, arguments)
      RequestBuilder.build(operation: operation, arguments: arguments, connector: operation.api_connector, project: @project)
    end

    def secret(name, value)
      create(:config_item, scope: @project, name: name, item_type: :secret, value: value)
    end

    test "encodes a path value containing / and .. as one segment" do
      request = build_request(operation(connector), { "path" => { "id" => "../admin?x=1#top" } })

      assert_equal "/v1/things/..%2Fadmin%3Fx%3D1%23top", request.uri.path
      assert_nil request.uri.query
      assert_equal "api.example.com", request.uri.host
    end

    test "refuses a path value that is only dots or empty" do
      op = operation(connector)

      [ ".", "..", "" ].each do |value|
        assert_raises(RequestBuilder::Invalid, value.inspect) { build_request(op, { "path" => { "id" => value } }) }
      end
    end

    test "refuses a missing or structured path value" do
      op = operation(connector)

      assert_raises(RequestBuilder::Invalid) { build_request(op, {}) }
      assert_raises(RequestBuilder::Invalid) { build_request(op, { "path" => { "id" => { "a" => 1 } } }) }
    end

    test "refuses arguments that would change the host" do
      op = operation(connector)

      [ "https://evil.example/x", "@evil.example", "//evil.example" ].each do |value|
        assert_equal "api.example.com", build_request(op, { "path" => { "id" => value } }).uri.host
      end

      bare = operation(connector(base_url: "https://api.example.com"))
      bare.update_column(:path, ".evil.example/{id}")
      error = assert_raises(RequestBuilder::Invalid) { build_request(bare, { "path" => { "id" => "1" } }) }
      assert_no_match(/evil/, error.message)
    end

    test "appends query arguments and sends the body as JSON" do
      op = operation(connector, verb: "POST")

      request = build_request(op, { "path" => { "id" => 7 }, "query" => { "q" => "a b", "tags" => %w[x y], "skip" => nil },
                            "body" => { "amount" => 5 } })

      assert_equal "POST", request.method
      assert_equal "/v1/things/7", request.uri.path
      assert_equal "q=a+b&tags=x&tags=y", request.uri.query
      assert_equal({ "amount" => 5 }, JSON.parse(request.body))
      assert_equal "application/json", request.headers["Content-Type"]
      assert_equal "application/json", request.headers["Accept"]
    end

    test "sends the connector's default headers" do
      request = build_request(operation(connector(default_headers: { "X-Api-Version" => "2", "Accept-Encoding" => "gzip" })),
                              { "path" => { "id" => "1" } })

      assert_equal "2", request.headers["X-Api-Version"]
      assert_equal({ "Accept-Encoding" => "identity" }, request.headers.select { |name, _| name.casecmp?("accept-encoding") })
      assert_empty request.secrets
      assert_empty request.config_item_names
    end

    test "puts api_key_query in the query string from the config item" do
      secret("API_KEY", "k-123 &=x")
      target = connector(auth_type: "api_key_query", auth_config: { "config_item_name" => "API_KEY", "query_param" => "api_key" })

      request = build_request(operation(target), { "path" => { "id" => "1" }, "query" => { "q" => "z", "api_key" => "spoof" } })

      assert_equal [ %w[q z], [ "api_key", "k-123 &=x" ] ], URI.decode_www_form(request.uri.query)
      assert_includes request.secrets, "k-123 &=x"
      assert_includes request.secrets, URI.encode_www_form_component("k-123 &=x")
      assert_equal [ "API_KEY" ], request.config_item_names
      assert_not request.headers.key?("Authorization")
    end

    test "bearer and api_key_header put the item in a header" do
      secret("TOKEN", "tok-1")
      bearer = build_request(operation(connector(auth_type: "bearer", auth_config: { "config_item_name" => "TOKEN" })),
                     { "path" => { "id" => "1" } })
      keyed = build_request(operation(connector(auth_type: "api_key_header",
                                        auth_config: { "config_item_name" => "TOKEN", "header_name" => "X-Api-Key" })),
                    { "path" => { "id" => "1" } })

      assert_equal "Bearer tok-1", bearer.headers["Authorization"]
      assert_includes bearer.secrets, "tok-1"
      assert_includes bearer.secrets, "Bearer tok-1"
      assert_equal "tok-1", keyed.headers["X-Api-Key"]
      assert_includes keyed.secrets, "tok-1"
    end

    test "keeps Accept-Encoding identity even when the auth header names it" do
      secret("TOKEN", "tok-1")
      target = connector(auth_type: "api_key_header", auth_config: { "config_item_name" => "TOKEN", "header_name" => "X-Api-Key" })
      target.update_column(:auth_config, { "config_item_name" => "TOKEN", "header_name" => "accept-encoding" })

      request = build_request(operation(target.reload), { "path" => { "id" => "1" } })

      assert_equal({ "Accept-Encoding" => "identity" }, request.headers.select { |name, _| name.casecmp?("accept-encoding") })
    end

    test "basic auth from two items" do
      create(:config_item, scope: @project, name: "API_USER", item_type: :variable, value: "alice")
      secret("API_PASS", "s3cret")
      target = connector(auth_type: "basic", auth_config: { "username_item" => "API_USER", "password_item" => "API_PASS" })

      request = build_request(operation(target), { "path" => { "id" => "1" } })

      token = Base64.strict_encode64("alice:s3cret")
      assert_equal "Basic #{token}", request.headers["Authorization"]
      [ "alice", "s3cret", token, "Basic #{token}" ].each { |value| assert_includes request.secrets, value }
      assert_equal %w[API_USER API_PASS], request.config_item_names
    end

    test "raises Missing for an item that is absent, blank or in another project" do
      create(:config_item, scope: create(:project, :standalone), name: "OTHER", item_type: :secret, value: "x")
      %w[ABSENT OTHER].each do |name|
        target = connector(auth_type: "bearer", auth_config: { "config_item_name" => name })

        assert_raises(ConfigItems::ReferenceResolver::Missing) { build_request(operation(target), { "path" => { "id" => "1" } }) }
      end
    end
  end
end

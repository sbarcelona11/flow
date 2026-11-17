# frozen_string_literal: true

require "test_helper"

module Rest
  class OperationCallerTest < ActiveSupport::TestCase
    BASE = "https://api.example.com/v1"

    setup do
      resolve_hosts_publicly!
      @project = create(:project, :standalone)
      @connector = create(:api_connector, scope: @project, base_url: BASE)
    end

    def operation(verb: "GET", path: "/things/{id}", connector: @connector)
      schema = { "type" => "object",
                 "properties" => { "path" => { "type" => "object", "properties" => { "id" => { "type" => "string" } },
                                               "required" => [ "id" ] } } }
      FactoryBot.build(:api_operation, api_connector: connector, path: path, input_schema: schema,
                                       effect: verb == "GET" ? "read" : "write").tap { |op| op[:method] = verb }.tap(&:save!)
    end

    def call(op = operation, arguments: { "path" => { "id" => "7" } })
      OperationCaller.call(operation: op, arguments: arguments, project: @project)
    end

    def stub_thing(verb = :get)
      stub_request(verb, "#{BASE}/things/7")
    end

    def secured_connector
      create(:config_item, scope: @project, name: "API_KEY", item_type: :secret, value: "k-secret-1")
      @connector.update!(auth_type: "api_key_query", auth_config: { "config_item_name" => "API_KEY", "query_param" => "key" })
    end

    def capture_log
      io = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = original
    end

    test "a 200 JSON body becomes structured" do
      stub_thing.to_return(status: 200, body: { "id" => 7, "name" => "x" }.to_json,
                           headers: { "Content-Type" => "application/json; charset=utf-8" })

      result = call

      assert_predicate result, :ok?
      assert_equal 200, result.status
      assert_equal({ "id" => 7, "name" => "x" }, result.structured)
      assert_nil result.error
    end

    test "a non-JSON body is returned as text" do
      stub_thing.to_return(status: 200, body: "plain answer", headers: { "Content-Type" => "text/plain" })

      result = call

      assert_predicate result, :ok?
      assert_nil result.structured
      assert_equal "plain answer", result.text
    end

    test "sends the method, headers and body the builder made" do
      create(:config_item, scope: @project, name: "TOKEN", item_type: :secret, value: "tok-1")
      @connector.update!(auth_type: "bearer", auth_config: { "config_item_name" => "TOKEN" })
      stub_thing(:post).to_return(status: 201, body: "")

      result = call(operation(verb: "POST"), arguments: { "path" => { "id" => "7" }, "body" => { "a" => 1 } })

      assert_predicate result, :ok?
      assert_equal [ "TOKEN" ], result.config_item_names
      assert_requested(:post, "#{BASE}/things/7", body: { "a" => 1 }.to_json,
                                                  headers: { "Authorization" => "Bearer tok-1", "Content-Type" => "application/json",
                                                             "Accept-Encoding" => "identity" })
    end

    test "a 404 is a known failure with a redacted body excerpt" do
      secured_connector
      stub_request(:get, "#{BASE}/things/7?key=k-secret-1").to_return(status: 404, body: "no thing for k-secret-1 #{'x' * 1000}")

      result = call

      assert_not result.ok?
      assert_not result.unknown?
      assert_equal 404, result.status
      assert_includes result.error, "no thing for [redacted]"
      assert_operator result.error.length, :<, 700
    end

    test "a 503 is unknown" do
      stub_thing.to_return(status: 503)

      result = call

      assert_not result.ok?
      assert_predicate result, :unknown?
      assert_equal 503, result.status
    end

    test "a 302 on POST is unknown and not followed" do
      stub_thing(:post).to_return(status: 302, headers: { "Location" => "https://evil.example/x" })
      stub_request(:any, /evil\.example/)

      result = call(operation(verb: "POST"))

      assert_not result.ok?
      assert_predicate result, :unknown?
      assert_equal 302, result.status
      assert_not_requested :any, /evil\.example/
    end

    test "a redirect body over the cap is read no further and keeps the redirect classification" do
      huge = "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1)
      stub_thing(:post).to_return(status: 302, body: huge, headers: { "Location" => "https://evil.example/x" })
      stub_thing.to_return(status: 302, body: huge, headers: { "Location" => "https://evil.example/x" })

      posted = call(operation(verb: "POST"))
      got = call

      assert_not posted.ok?
      assert_predicate posted, :unknown?
      assert_equal 302, posted.status
      assert_not got.ok?
      assert_not got.unknown?
      assert_equal 302, got.status
    end

    test "a 301 on GET is a known failure" do
      stub_thing.to_return(status: 301, headers: { "Location" => "https://evil.example/x" })

      result = call

      assert_not result.ok?
      assert_not result.unknown?
    end

    test "a read timeout after send is unknown" do
      [ Net::ReadTimeout, Errno::ECONNRESET, EOFError, OpenSSL::SSL::SSLError.new("SSL_read: unexpected eof") ].each do |error|
        WebMock.reset!
        stub_thing(:post).to_raise(error)

        result = call(operation(verb: "POST"))

        assert_not result.ok?
        assert_predicate result, :unknown?, error.inspect
        assert_nil result.status
      end
    end

    test "ECONNREFUSED is a known failure" do
      [ Errno::ECONNREFUSED, Net::OpenTimeout, SocketError.new("getaddrinfo: Name or service not known"),
        OpenSSL::SSL::SSLError.new("SSL_connect returned=1 errno=0 state=error: certificate verify failed") ].each do |error|
        WebMock.reset!
        stub_thing(:post).to_raise(error)

        result = call(operation(verb: "POST"))

        assert_not result.ok?
        assert_not result.unknown?, error.inspect
      end
    end

    test "a body over 10 MB fails without reading it all" do
      stub_thing(:post).to_return(status: 200, body: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1))

      result = call(operation(verb: "POST"))

      assert_not result.ok?
      assert_predicate result, :unknown?
      assert_match(/10 MB/, result.error)

      WebMock.reset!
      stub_thing.to_return(status: 200, body: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1))

      assert_not call.unknown?
    end

    test "no secret appears in error, text or log" do
      secured_connector
      url = "#{BASE}/things/7?key=k-secret-1"
      results = []

      log = capture_log do
        stub_request(:get, url).to_return(status: 200, body: "echo k-secret-1", headers: { "Content-Type" => "text/plain" })
        results << call
        stub_request(:get, url).to_return(status: 500, body: "boom k-secret-1")
        results << call
        stub_request(:get, url).to_raise(StandardError.new("failed at #{url}"))
        results << call
      end

      assert_equal "echo [redacted]", results.first.text
      results.drop(1).each { |result| assert_no_match(/k-secret-1|\?key=/, result.error) }
      assert_no_match(/k-secret-1|\?key=/, log)
      assert_match(%r{GET /things/\{id\}}, log)
    end

    test "refuses a connector whose base URL is no longer safe" do
      @connector.update_column(:base_url, "https://169.254.169.254/latest")

      result = call

      assert_not result.ok?
      assert_not result.unknown?
      assert_not_requested :any, /169\.254/
    end

    test "refuses an operation of another project" do
      other = create(:api_connector, scope: create(:project, :standalone), base_url: BASE)

      result = call(operation(connector: other))

      assert_not result.ok?
      assert_not result.unknown?
      assert_not_requested :any, /api\.example\.com/
    end

    test "an invalid path argument is a known failure that sends nothing" do
      result = call(arguments: { "path" => { "id" => ".." } })

      assert_not result.ok?
      assert_not result.unknown?
      assert_not_requested :any, /api\.example\.com/
    end

    test "a header value with a line break is a known failure that sends nothing" do
      create(:config_item, scope: @project, name: "API_KEY", item_type: :secret, value: "k-1\r\nX-Injected: 1")
      @connector.update!(auth_type: "api_key_header", auth_config: { "config_item_name" => "API_KEY", "header_name" => "X-Api-Key" })

      result = call(operation(verb: "POST"))

      assert_not result.ok?
      assert_not result.unknown?
      assert_no_match(/X-Injected/, result.error)
      assert_not_requested :any, /api\.example\.com/
    end

    test "hands back a redactor for the secrets it sent" do
      secured_connector
      stub_request(:get, "#{BASE}/things/7?key=k-secret-1").to_return(status: 204)

      assert_equal "near [redacted]", call.redactor.call("near k-secret-1")
    end
  end
end

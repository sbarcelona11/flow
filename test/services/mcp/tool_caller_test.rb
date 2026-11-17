# frozen_string_literal: true

require "test_helper"

module MCP
  # Contract tests for the session-free tool call: the gem runs for real against
  # a WebMock-stubbed server (R4), never stubbed itself (R2).
  class ToolCallerTest < ActiveSupport::TestCase
    MCP_URL = "https://mcp.example.com/mcp"

    setup do
      resolve_hosts_publicly!
      @project = create(:project, :standalone)
      @user = create(:user, company: @project.company)
    end

    def server(**attrs)
      @project.mcp_servers.create!({ name: "Billing", url: MCP_URL, transport: :http }.merge(attrs))
    end

    def rpc_method(request) = JSON.parse(request.body)["method"]

    def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

    def stub_handshake
      stub_request(:post, MCP_URL).with { |req| rpc_method(req) != "tools/call" }.to_return do |request|
        message = JSON.parse(request.body)
        next { status: 202 } unless message["id"]

        json(jsonrpc: "2.0", id: message["id"],
             result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "example", version: "1.0.0" } })
      end
    end

    def tool_call_stub
      stub_request(:post, MCP_URL).with { |req| rpc_method(req) == "tools/call" }
    end

    def stub_call(result: { content: [ { type: "text", text: "done" } ] }, error: nil)
      stub_handshake
      tool_call_stub.to_return do |request|
        id = JSON.parse(request.body)["id"]
        json(error ? { jsonrpc: "2.0", id: id, error: error } : { jsonrpc: "2.0", id: id, result: result })
      end
    end

    def oauth_credential(owner:, server:, access_token:)
      credential = OauthCredential.new(owner: owner, oauth_client: create(:oauth_client), provider: "mcp",
                                       mcp_server: server, status: :active)
      credential.access_token = access_token
      credential.expires_at = 1.hour.from_now
      credential.save!
      credential
    end

    def tool_call_requested(&)
      assert_requested(:post, MCP_URL) { |req| rpc_method(req) == "tools/call" && yield(req) }
    end

    def call(target, user: nil) = ToolCaller.call(server: target, tool: "t", arguments: {}, user: user)

    test "sends the tool call with resolved headers" do
      create(:config_item, scope: @project, name: "BILLING_KEY", item_type: :secret, value: "k-123")
      stub_call(result: { content: [ { type: "text", text: "created" } ], structuredContent: { "id" => 7 } })

      result = ToolCaller.call(server: server(headers: { "X-Api-Key" => "config_item:BILLING_KEY" }),
                               tool: "create_invoice", arguments: { "amount" => 5 }, user: @user)

      assert_predicate result, :ok?
      assert_equal({ "id" => 7 }, result.structured)
      assert_equal "created", result.text
      assert_equal [ "BILLING_KEY" ], result.config_item_names
      tool_call_requested do |req|
        body = JSON.parse(req.body)
        req.headers["X-Api-Key"] == "k-123" &&
          body.dig("params", "name") == "create_invoice" && body.dig("params", "arguments") == { "amount" => 5 }
      end
    end

    test "adds the run owner's OAuth token for a per-user server" do
      target = server(auth_type: :oauth, credential_scope: :per_user)
      oauth_credential(owner: @user, server: target, access_token: "owner-token")
      oauth_credential(owner: create(:user, company: @project.company), server: target, access_token: "other-token")
      stub_call

      assert_predicate call(target, user: @user), :ok?
      tool_call_requested { |req| req.headers["Authorization"] == "Bearer owner-token" }
    end

    test "a shared OAuth server uses its own credential and ignores the user" do
      target = server(auth_type: :oauth, credential_scope: :shared)
      oauth_credential(owner: @project, server: target, access_token: "project-token")
      oauth_credential(owner: @user, server: target, access_token: "user-token")
      stub_call

      assert_predicate call(target, user: @user), :ok?
      tool_call_requested { |req| req.headers["Authorization"] == "Bearer project-token" }
    end

    test "raises AuthRequired without an owner" do
      target = server(auth_type: :oauth, credential_scope: :per_user)
      oauth_credential(owner: @user, server: target, access_token: "owner-token")

      error = assert_raises(ToolCaller::AuthRequired) { call(target) }
      assert_match(/Billing/, error.message)
      assert_not_requested :post, MCP_URL
    end

    test "raises AuthRequired when the owner has not connected the server" do
      error = assert_raises(ToolCaller::AuthRequired) { call(server(auth_type: :oauth, credential_scope: :per_user), user: @user) }

      assert_match(/Billing/, error.message)
      assert_not_requested :post, MCP_URL
    end

    test "raises AuthRequired naming the server when it answers 401" do
      stub_handshake
      tool_call_stub.to_return(status: 401, headers: { "WWW-Authenticate" => "Bearer" })

      error = assert_raises(ToolCaller::AuthRequired) { call(server) }
      assert_match(/Billing/, error.message)
    end

    test "maps isError to a failed result without echoing headers" do
      create(:config_item, scope: @project, name: "BILLING_KEY", item_type: :secret, value: "k-123")
      target = server(auth_type: :oauth, credential_scope: :per_user,
                      headers: { "X-Api-Key" => "config_item:BILLING_KEY", "X-Static-Token" => "static-secret" })
      oauth_credential(owner: @user, server: target, access_token: "owner-token")
      stub_call(result: { isError: true,
                          content: [ { type: "text", text: "rejected key k-123, static-secret and Bearer owner-token" } ] })

      result = call(target, user: @user)

      assert_not result.ok?
      assert_not result.unknown?
      assert_equal "rejected key [redacted], [redacted] and Bearer [redacted]", result.error
    end

    test "redacts the bare credential of a literal Authorization header" do
      stub_call(result: { content: [ { type: "text", text: "token sk-live-abcdef12 is fine" } ] })

      result = call(server(headers: { "Authorization" => "Bearer sk-live-abcdef12" }))

      assert_equal "token [redacted] is fine", result.text
    end

    test "redacts a secret as it appears inside JSON text, keys included" do
      create(:config_item, scope: @project, name: "PASS", item_type: :secret, value: 'pa"ss-word')
      echoed = { "auth" => 'pa"ss-word' }.to_json
      stub_call(result: { content: [ { type: "text", text: echoed } ], structuredContent: { 'pa"ss-word' => "x" } })

      result = call(server(headers: { "X-Pass" => "config_item:PASS" }))

      assert_equal '{"auth":"[redacted]"}', result.text
      assert_equal({ "[redacted]" => "x" }, result.structured)
    end

    test "leaves non-secret header values and variables in the result alone" do
      create(:config_item, scope: @project, name: "REGION", item_type: :variable, value: "eu-west-1")
      text = "accept application/json, version 2, region eu-west-1"
      stub_call(result: { content: [ { type: "text", text: text } ], structuredContent: { "region" => "eu-west-1" } })

      result = call(server(headers: { "Accept" => "application/json", "X-Api-Version" => "2", "X-Region" => "config_item:REGION" }))

      assert_equal text, result.text
      assert_equal({ "region" => "eu-west-1" }, result.structured)
    end

    test "maps a JSON-RPC error to a known failure without echoing headers" do
      stub_call(error: { code: -32_000, message: "bad key static-secret" })

      result = call(server(auth_type: :static, headers: { "X-Static" => "static-secret" }))

      assert_not result.ok?
      assert_not result.unknown?
      assert_equal "bad key [redacted]", result.error
    end

    test "a 4xx answer to the tool call is a known failure" do
      stub_handshake
      tool_call_stub.to_return(status: 422)

      result = call(server)

      assert_not result.ok?
      assert_not result.unknown?
    end

    test "a gateway timeout during the tool call leaves the outcome unknown" do
      stub_handshake
      tool_call_stub.to_return(status: 504, body: "upstream refused static-secret")

      result = call(server(auth_type: :static, headers: { "X-Static" => "static-secret" }))

      assert_not result.ok?
      assert_predicate result, :unknown?
      assert_no_match(/static-secret/, result.error)
    end

    test "a connection reset or read timeout after sending leaves the outcome unknown" do
      target = server
      stub_handshake
      tool_call_stub.to_raise(Errno::ECONNRESET)

      assert_predicate call(target), :unknown?

      WebMock.reset!
      stub_handshake
      tool_call_stub.to_raise(Net::ReadTimeout)

      assert_predicate call(target), :unknown?
    end

    test "a refused connection is a known failure" do
      stub_handshake
      tool_call_stub.to_raise(Errno::ECONNREFUSED)

      result = call(server)

      assert_not result.ok?
      assert_not result.unknown?
    end

    test "a timeout during the handshake is a known failure and never sends the call" do
      stub_request(:post, MCP_URL).to_raise(Net::ReadTimeout)

      result = call(server)

      assert_not result.ok?
      assert_not result.unknown?
      assert_not_requested(:post, MCP_URL) { |req| rpc_method(req) == "tools/call" }
    end

    test "reports an unexpected error by its class, not its message" do
      stub_handshake
      tool_call_stub.to_return do |req|
        json(jsonrpc: "2.0", id: JSON.parse(req.body)["id"],
             result: { resultType: "input_required", inputRequests: { "a" => { "method" => "static-secret" } } })
      end

      result = call(server(auth_type: :static, headers: { "X-Static" => "static-secret" }))

      assert_not result.ok?
      assert_match(/\A\S+ while calling Billing\z/, result.error)
      assert_predicate result, :unknown?
    end

    test "a malformed answer to the tool call leaves the outcome unknown" do
      stub_handshake
      tool_call_stub.to_return { |req| json(jsonrpc: "2.0", id: JSON.parse(req.body)["id"], result: "done") }

      result = call(server)

      assert_not result.ok?
      assert_predicate result, :unknown?
    end

    test "refuses a private address" do
      target = server
      target.update_column(:url, "http://169.254.169.254/latest/meta-data")

      result = call(target.reload)

      assert_not result.ok?
      assert_not result.unknown?
      assert_predicate result.error, :present?
      assert_not_requested :post, %r{169\.254\.169\.254}
    end

    test "refuses a stdio server" do
      result = call(server(transport: :stdio, url: nil, command: "npx", args: [ "pkg@1.0.0" ]))

      assert_not result.ok?
      assert_match(/stdio/, result.error)
    end

    test "raises Missing for a header naming an unknown config item" do
      assert_raises(ConfigItems::ReferenceResolver::Missing) do
        call(server(headers: { "X-Api-Key" => "config_item:ABSENT" }))
      end
      assert_not_requested :post, MCP_URL
    end
  end
end

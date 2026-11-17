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

    def stub_call(result: { content: [ { type: "text", text: "done" } ] }, error: nil)
      stub_request(:post, MCP_URL).to_return do |request|
        message = JSON.parse(request.body)
        body =
          case message["method"]
          when "tools/call"
            error ? { jsonrpc: "2.0", id: message["id"], error: error } : { jsonrpc: "2.0", id: message["id"], result: result }
          when "initialize"
            { jsonrpc: "2.0", id: message["id"], result: { protocolVersion: "2025-06-18", capabilities: { tools: {} },
                                                           serverInfo: { name: "example", version: "1.0.0" } } }
          else
            { jsonrpc: "2.0", id: message["id"], error: { code: -32_601, message: "Method not found" } }
          end
        { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
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
      assert_requested(:post, MCP_URL) { |req| JSON.parse(req.body)["method"] == "tools/call" && yield(req) }
    end

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

      assert_predicate ToolCaller.call(server: target, tool: "search", arguments: {}, user: @user), :ok?
      tool_call_requested { |req| req.headers["Authorization"] == "Bearer owner-token" }
    end

    test "raises AuthRequired without an owner" do
      target = server(auth_type: :oauth, credential_scope: :per_user)
      oauth_credential(owner: @user, server: target, access_token: "owner-token")

      error = assert_raises(ToolCaller::AuthRequired) do
        ToolCaller.call(server: target, tool: "search", arguments: {}, user: nil)
      end
      assert_match(/Billing/, error.message)
      assert_not_requested :post, MCP_URL
    end

    test "raises AuthRequired when the owner has not connected the server" do
      target = server(auth_type: :oauth, credential_scope: :per_user)

      error = assert_raises(ToolCaller::AuthRequired) do
        ToolCaller.call(server: target, tool: "search", arguments: {}, user: @user)
      end
      assert_match(/Billing/, error.message)
      assert_not_requested :post, MCP_URL
    end

    test "maps isError to a failed result without echoing headers" do
      create(:config_item, scope: @project, name: "BILLING_KEY", item_type: :secret, value: "k-123")
      target = server(auth_type: :oauth, credential_scope: :per_user,
                      headers: { "X-Api-Key" => "config_item:BILLING_KEY", "X-Static" => "static-secret" })
      oauth_credential(owner: @user, server: target, access_token: "owner-token")
      stub_call(result: { isError: true,
                          content: [ { type: "text", text: "rejected key k-123, static-secret and Bearer owner-token" } ] })

      result = ToolCaller.call(server: target, tool: "create_invoice", arguments: {}, user: @user)

      assert_not result.ok?
      assert_match(/rejected key/, result.error)
      [ "k-123", "static-secret", "owner-token" ].each do |secret|
        assert_no_match(/#{secret}/, result.error)
        assert_no_match(/#{secret}/, result.text.to_s)
      end
      assert_match(/\[redacted\]/, result.error)
    end

    test "maps a JSON-RPC error to a failed result without echoing headers" do
      stub_call(error: { code: -32_000, message: "bad key static-secret" })

      result = ToolCaller.call(server: server(headers: { "X-Static" => "static-secret" }), tool: "t", arguments: {}, user: nil)

      assert_not result.ok?
      assert_equal "bad key [redacted]", result.error
    end

    test "maps a transport error to a failed result without echoing headers" do
      stub_request(:post, MCP_URL).to_return(status: 500, body: "upstream refused static-secret")

      result = ToolCaller.call(server: server(headers: { "X-Static" => "static-secret" }), tool: "t", arguments: {}, user: nil)

      assert_not result.ok?
      assert_predicate result.error, :present?
      assert_no_match(/static-secret/, result.error)
    end

    test "reports a read timeout as an unknown outcome, and a refused connection as a failure" do
      target = server
      stub_request(:post, MCP_URL).to_raise(Net::ReadTimeout)

      read_timeout = ToolCaller.call(server: target, tool: "t", arguments: {}, user: nil)

      assert_not read_timeout.ok?
      assert_predicate read_timeout, :unknown?

      WebMock.reset!
      stub_request(:post, MCP_URL).to_timeout

      assert_not ToolCaller.call(server: target, tool: "t", arguments: {}, user: nil).unknown?
    end

    test "refuses a private address" do
      target = server
      target.update_column(:url, "http://169.254.169.254/latest/meta-data")

      result = ToolCaller.call(server: target.reload, tool: "t", arguments: {}, user: nil)

      assert_not result.ok?
      assert_not result.unknown?
      assert_predicate result.error, :present?
      assert_not_requested :post, %r{169\.254\.169\.254}
    end

    test "refuses a stdio server" do
      target = server(transport: :stdio, url: nil, command: "npx", args: [ "pkg@1.0.0" ])

      result = ToolCaller.call(server: target, tool: "t", arguments: {}, user: nil)

      assert_not result.ok?
      assert_match(/stdio/, result.error)
    end

    test "raises Missing for a header naming an unknown config item" do
      assert_raises(ConfigItems::ReferenceResolver::Missing) do
        ToolCaller.call(server: server(headers: { "X-Api-Key" => "config_item:ABSENT" }), tool: "t", arguments: {}, user: nil)
      end
      assert_not_requested :post, MCP_URL
    end
  end
end

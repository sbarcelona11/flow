# frozen_string_literal: true

require "test_helper"

class Connectors::Transports::MCPContractTest < ActiveSupport::TestCase
  include Connectors::TransportContract

  MCP_URL = "https://mcp.example.com/mcp"
  SECRET = "k-secret-1-pxk_live_7Hq2ZtR9mWb4Nc8VxL1aPe6Ks3Dy5Fg0Ju"

  setup do
    resolve_hosts_publicly!
    @project = create(:project, :standalone)
    create(:config_item, scope: @project, name: "BILLING_KEY", item_type: :secret, value: SECRET)
    @server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing", transport: :http, url: MCP_URL,
                                                      headers: { "X-Api-Key" => "config_item:BILLING_KEY" },
                                                      snapshot_tools: [ { "name" => "search", "description" => "Find invoices",
                                                                          "input_schema" => { "type" => "object" },
                                                                          "annotations" => { "readOnlyHint" => true } } ])
  end

  def transport = @transport ||= Connectors::Registry.fetch(:mcp).new
  def connection = @server
  def operation = transport.operations(@server).first
  def context = Connectors::Context.new(project: @project, user: nil, step_run_id: 1, run_id: 2)
  def secret = SECRET
  def backend_calls = WebMock::RequestRegistry.instance.times_executed(tool_call_pattern)

  def stub_backend(outcome)
    stub_handshake
    stub = stub_request(:post, MCP_URL).with { |req| rpc_method(req) == "tools/call" }
    case outcome
    when :success then stub.to_return { |req| answer(req, result: { content: [ { type: "text", text: "done" } ] }) }
    when :known_failure then stub.to_return { |req| answer(req, result: { isError: true, content: [ { type: "text", text: "no" } ] }) }
    when :unknown_after_send then stub.to_return(status: 503, body: "unavailable")
    when :timeout_before_send then stub.to_raise(Net::OpenTimeout)
    when :oversize
      stub.to_return { |req| answer(req, result: { content: [ { type: "text", text: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1) } ] }) }
    when :secret_echo_structured
      stub.to_return do |req|
        answer(req, result: { content: [ { type: "text", text: "ok" } ],
                              structuredContent: { SECRET => 1, "nested" => [ { "token" => SECRET } ] } })
      end
    when :secret_echo
      stub.to_return { |req| answer(req, result: { content: [ { type: "text", text: "you sent #{SECRET}" } ] }) }
    end
  end

  private

  def rpc_method(request) = JSON.parse(request.body)["method"]

  def tool_call_pattern = WebMock::RequestPattern.new(:post, MCP_URL).with { |req| rpc_method(req) == "tools/call" }

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def answer(request, result:) = json(jsonrpc: "2.0", id: JSON.parse(request.body)["id"], result: result)

  def stub_handshake
    stub_request(:post, MCP_URL).with { |req| rpc_method(req) != "tools/call" }.to_return do |request|
      message = JSON.parse(request.body)
      next { status: 202 } unless message["id"]

      answer(request, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} },
                                serverInfo: { name: "example", version: "1.0.0" } })
    end
  end
end

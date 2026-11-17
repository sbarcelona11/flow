# frozen_string_literal: true

require "test_helper"

class Connectors::Transports::RestContractTest < ActiveSupport::TestCase
  include Connectors::TransportContract

  BASE = "https://api.example.com/v1"
  SECRET = "k-secret-1-pxk_live_7Hq2ZtR9mWb4Nc8VxL1aPe6Ks3Dy5Fg0Ju"

  setup do
    resolve_hosts_publicly!
    @project = create(:project, :standalone)
    create(:config_item, scope: @project, name: "API_KEY", item_type: :secret, value: SECRET)
    @connector = create(:api_connector, scope: @project, name: "Payments", base_url: BASE, auth_type: "bearer",
                                        auth_config: { "config_item_name" => "API_KEY" })
    @api_operation = create(:api_operation, api_connector: @connector, name: "refund", http_method: "POST", path: "/charges",
                                            effect: "write", description: "Refund a charge")
  end

  def transport = @transport ||= Connectors::Registry.fetch(:rest).new
  def connection = @api_operation
  def operation = transport.operations(@api_operation).first
  def context = Connectors::Context.new(project: @project, user: nil, step_run_id: 1, run_id: 2)
  def secret = SECRET
  def backend_calls = WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:post, "#{BASE}/charges"))

  def stub_backend(outcome)
    stub = stub_request(:post, "#{BASE}/charges")
    case outcome
    when :success then stub.to_return(status: 200, body: { "id" => 1 }.to_json, headers: { "Content-Type" => "application/json" })
    when :known_failure then stub.to_return(status: 422, body: "invalid")
    when :unknown_after_send then stub.to_return(status: 503, body: "unavailable")
    when :timeout_before_send then stub.to_raise(Net::OpenTimeout)
    when :oversize then stub.to_return(status: 200, body: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1))
    when :secret_echo_structured
      stub.to_return(status: 200, body: { SECRET => 1, "nested" => [ { "token" => SECRET } ] }.to_json,
                     headers: { "Content-Type" => "application/json" })
    when :secret_echo then stub.to_return(status: 200, body: "you sent #{SECRET}", headers: { "Content-Type" => "text/plain" })
    end
  end
end

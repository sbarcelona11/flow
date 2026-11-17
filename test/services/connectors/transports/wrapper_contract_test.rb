# frozen_string_literal: true

require "test_helper"

class Connectors::Transports::WrapperContractTest < ActiveSupport::TestCase
  include Connectors::TransportContract

  SECRET = "k-secret-1-pxk_live_7Hq2ZtR9mWb4Nc8VxL1aPe6Ks3Dy5Fg0Ju"

  setup do
    @project = create(:project, :standalone)
    @tool = create(:tool, scope: @project, name: "invoice_lines", display_name: "Invoice lines",
                          description: "Computes lines", input_schema: { "type" => "object" })
    step_run = create(:step_run)
    @tool_result = ToolResult.create!(tool: @tool, step_run: step_run, execution_id: ToolResult.generate_id, state: "processing")
    @context = Connectors::Context.new(project: @project, user: nil, step_run_id: step_run.id, run_id: step_run.workflow_run_id,
                                       tool_result_id: @tool_result.id)
    @starts = 0
  end

  def transport = @transport ||= Connectors::Registry.fetch(:wrapper).new
  def connection = @tool
  def operation = transport.operations(@tool).first
  def context = @context
  def secret = SECRET
  def backend_calls = @starts

  def stub_backend(outcome)
    case outcome
    when :success then start_answers(ok: true, workflow_id: "wf", run_id: "run")
    when :known_failure then start_answers(ok: false, error: "workflow already exists")
    when :unknown_after_send then start_answers(ok: false, error: "deadline exceeded", error_class: "Temporalio::Error::RPCError")
    when :timeout_before_send
      @tool.stubs(:container_manifest).with { @starts += 1 }.raises(Timeout::Error)
    when :oversize then skip "n/a for async"
    when :secret_echo, :secret_echo_structured then start_answers(ok: false, error: "rejected #{SECRET}")
    end
  end

  private

  def start_answers(answer)
    TemporalService.stubs(:start_workflow).with { @starts += 1 }.returns(answer)
    @tool.stubs(:container_manifest).returns({})
  end
end

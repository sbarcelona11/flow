# frozen_string_literal: true

require "test_helper"

class Connectors::TransportContractSelfTest < ActiveSupport::TestCase
  SECRET = "pxk_live_7Hq2ZtR9mWb4Nc8VxL1aPe6Ks3Dy5Fg0Ju"
  OPERATION = Connectors::Operation.new(key: "ping", name: "ping", description: nil, input_schema: { "type" => "object" },
                                        output_schema: nil, base_effect: "read", drifted: false)

  class FakeTransport < Connectors::Transport
    attr_reader :calls
    attr_accessor :outcome

    def calls = @calls ||= 0

    def operations(_connection) = [ OPERATION ]
    def label(_connection, operation) = "Fake · #{operation.name}"

    def call(connection:, operation:, arguments:, context:)
      @calls = calls + 1
      answer
    end

    private

    def redactor = ->(text) { text.to_s.gsub(SECRET, "[redacted]") }

    def answer
      case outcome
      when :success then Connectors::Result.new(ok: true, text: "pong", redactor: redactor)
      when :known_failure, :timeout_before_send then Connectors::Result.new(error: "refused", redactor: redactor)
      when :unknown_after_send then Connectors::Result.new(unknown: true, error: "may have been sent", redactor: redactor)
      when :oversize then Connectors::Result.new(error: "too large", redactor: redactor)
      when :secret_echo then Connectors::Result.new(ok: true, text: "echo #{SECRET}", redactor: redactor)
      end
    end
  end

  class RetryingTransport < FakeTransport
    def call(...)
      result = super
      result.ok? ? result : super
    end
  end

  class LeakingTransport < FakeTransport
    private

    def redactor = nil
  end

  class CarriesOversizeBodyTransport < FakeTransport
    private

    def answer = outcome == :oversize ? Connectors::Result.new(error: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1)) : super
  end

  class MisclassifyingTransport < FakeTransport
    private

    def answer
      result = super
      result.unknown = true if outcome == :known_failure
      result
    end
  end

  module Harness
    def self.included(base)
      base.include Connectors::TransportContract
    end

    def transport = @transport ||= self.class::TRANSPORT.new
    def connection = nil
    def operation = OPERATION
    def context = Connectors::Context.new(project: nil, user: nil, step_run_id: 1, run_id: 1)
    def secret = SECRET
    def backend_calls = transport.calls
    def stub_backend(outcome) = transport.outcome = outcome
  end

  def self.contract_class(transport_class)
    Class.new(ActiveSupport::TestCase) do
      const_set(:TRANSPORT, transport_class)
      include Harness
    end.tap { |klass| Minitest::Runnable.runnables.delete(klass) }
  end

  def failures_of(transport_class)
    klass = self.class.contract_class(transport_class)
    klass.runnable_methods.select { |name| name.start_with?("test_contract") }.reject do |name|
      klass.new(name).run.passed? || klass.new(name).run.skipped?
    end
  end

  test "a transport that honours the port passes every contract test" do
    assert_empty failures_of(FakeTransport)
  end

  test "a transport that retries a failed call fails the no-retry contract" do
    assert_includes failures_of(RetryingTransport), "test_contract:_known_failure_is_attempted_once,_never_retried"
  end

  test "a transport that leaks the secret without a redactor fails the redaction contract" do
    assert_includes failures_of(LeakingTransport),
                    "test_contract:_a_secret_the_backend_echoes_appears_nowhere_in_the_result_once_redacted"
  end

  test "a transport that carries an oversize body fails the size contract" do
    assert_includes failures_of(CarriesOversizeBodyTransport),
                    "test_contract:_an_oversize_answer_is_a_failure_and_its_body_is_not_carried"
  end

  test "a transport that reports a definite rejection as unknown fails the classification contract" do
    assert_includes failures_of(MisclassifyingTransport), "test_contract:_a_definite_rejection_is_a_known_failure"
  end
end

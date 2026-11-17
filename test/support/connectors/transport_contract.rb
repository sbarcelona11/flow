# frozen_string_literal: true

require_relative "../secret_leak_assertions"

module Connectors
  # What every Connectors::Transport must honour, whatever it talks to. A transport's test includes this module and
  # supplies:
  #
  #   transport, connection, operation, context  the instance under test and what to call it with
  #   secret                                      the string the backend echoes for :secret_echo
  #   stub_backend(outcome)                       makes the backend answer as described, mapped onto the transport's
  #                                               own seam (WebMock, a service seam, the container start)
  #   backend_calls                               attempts at whichever seam the outcome reaches (the HTTP request for
  #                                               REST and MCP; for Wrapper the start, or the manifest for
  #                                               :timeout_before_send)
  #
  # Outcomes: :success, :known_failure (definitely rejected), :unknown_after_send (the request may have been
  # received), :timeout_before_send (failed before anything left), :oversize (answered with more than
  # Step::ACTION_OUTPUT_MAX_BYTES), :secret_echo (answers with the secret in a plain body),
  # :secret_echo_structured (answers with the secret as a key and as a nested value of a JSON body).
  #
  # An async transport is judged at start: success is a handle in `structured`; the failure outcomes describe the start.
  module TransportContract
    include SecretLeakAssertions

    FAILURES = %i[known_failure unknown_after_send timeout_before_send oversize].freeze

    def self.included(base)
      base.class_eval do
        test "contract: a call returns a Connectors::Result" do
          assert_kind_of Connectors::Result, invoke(:success)
        end

        test "contract: a success is ok and carries no error" do
          result = invoke(:success)

          assert_predicate result, :ok?
          assert_not_predicate result, :unknown?
          assert_nil result.error
        end

        test "contract: an async start returns a handle and records nothing itself" do
          skip "n/a for sync: only an async transport returns a handle" unless transport.async?

          result = assert_no_difference(-> { contract_governance_footprint }) { invoke(:success) }

          assert_kind_of Hash, result.structured
          assert_predicate result.structured, :any?
        end

        test "contract: a definite rejection is a known failure" do
          result = invoke(:known_failure)

          assert_not_predicate result, :ok?
          assert_not_predicate result, :unknown?
          assert_predicate result.error, :present?
        end

        test "contract: a failure after the request may have been sent is unknown" do
          result = invoke(:unknown_after_send)

          assert_not_predicate result, :ok?
          assert_predicate result, :unknown?
        end

        test "contract: a failure before anything was sent is a known failure" do
          result = invoke(:timeout_before_send)

          assert_not_predicate result, :ok?
          assert_not_predicate result, :unknown?
        end

        test "contract: an oversize answer is a failure and its body is not carried" do
          skip "n/a for async: output arrives when the run finishes, not at start" if transport.async?

          result = invoke(:oversize)

          assert_not_predicate result, :ok?
          carried = [ result.error, result.text, result.structured&.to_json ].compact.sum(&:bytesize)
          assert_operator carried, :<, Step::ACTION_OUTPUT_MAX_BYTES
        end

        %i[secret_echo secret_echo_structured].each do |outcome|
          test "contract: #{outcome} appears nowhere in the result once redacted" do
            result = invoke(outcome)
            redact = result.redactor || :itself.to_proc

            contract_strings(result).each { |field| assert_no_secret redact.call(field), secret }
          end
        end

        FAILURES.each do |outcome|
          test "contract: #{outcome} is attempted once, never retried" do
            invoke(outcome)

            assert_equal 1, backend_calls
          end
        end

        test "contract: operations are valid Connectors::Operations" do
          operations = transport.operations(connection)

          assert_predicate operations, :any?
          operations.each do |entry|
            assert_kind_of Connectors::Operation, entry
            assert_empty SchemaHygiene.errors_for(entry.input_schema), "#{entry.key} input_schema"
            assert_includes Step::ACTION_EFFECTS, entry.base_effect, "#{entry.key} base_effect"
          end
        end

        test "contract: a label is a readable string that never holds the secret" do
          transport.operations(connection).each do |entry|
            label = transport.label(connection, entry)

            assert_kind_of String, label
            assert_predicate label, :present?
            assert_not_includes label, secret
            assert_not_includes transport.target_name(connection, entry).to_s, secret
          end
          assert_not_includes transport.owner(connection).to_s, secret
        end
      end
    end

    def contract_arguments = {}

    def contract_strings(result)
      [ result.error, result.text, *strings_in(result.structured) ].compact
    end

    def strings_in(value)
      case value
      when Hash then value.flat_map { |key, entry| [ key.to_s, *strings_in(entry) ] }
      when Array then value.flat_map { |entry| strings_in(entry) }
      when nil then []
      else [ value.to_s ]
      end
    end

    def contract_governance_footprint = ToolResult.count + StepRun.count

    def invoke(outcome)
      stub_backend(outcome)
      transport.call(connection: connection, operation: operation, arguments: contract_arguments, context: context)
    end
  end
end

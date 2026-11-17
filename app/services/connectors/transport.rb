# frozen_string_literal: true

module Connectors
  # The port every connector transport implements. A transport receives the
  # connection and a Connectors::Context (ids and read-only values, never a
  # StepRun), so it cannot write step runs or action calls.
  class Transport
    class << self
      attr_reader :transport_key, :transport_target

      def transport(key, target: key.to_s)
        @transport_key = key.to_sym
        @transport_target = target.to_s
      end
    end

    def operations(_connection) = not_implemented(:operations)
    def call(connection:, operation:, arguments:, context:) = not_implemented(:call)
    def probe(_connection) = not_implemented(:probe)
    def owner(_connection) = not_implemented(:owner)
    def label(_connection, _operation) = not_implemented(:label)
    def connection_for(_kind_config, _project) = not_implemented(:connection_for)

    private

    def not_implemented(method)
      raise NotImplementedError, "#{self.class.name || 'Connectors::Transport'}##{method} is not implemented"
    end
  end
end

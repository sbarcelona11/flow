# frozen_string_literal: true

module Connectors
  # A transport only makes the call. Governance (effect, approval, attempt marks, redaction, outputs) belongs to the
  # pipeline in front of the port, so nothing here may reimplement or skip it.
  class Transport
    class << self
      attr_reader :transport_key, :transport_target, :transport_position

      def transport(key, target: key.to_s, position: 100)
        @transport_key = key.to_sym
        @transport_target = target.to_s
        @transport_position = position
      end
    end

    def async? = false

    def connections(_project) = not_implemented(:connections)
    def operations(_connection) = not_implemented(:operations)
    def call(connection:, operation:, arguments:, context:) = not_implemented(:call)
    def probe(_connection) = not_implemented(:probe)
    def owner(_connection) = not_implemented(:owner)
    def label(_connection, _operation) = not_implemented(:label)
    def target_name(_connection, _operation) = not_implemented(:target_name)
    def connection_for(_kind_config, _project) = not_implemented(:connection_for)
    def connection_of(_action_call) = not_implemented(:connection_of)
    def connection_associations = []
    def target_attributes(_connection, _operation) = not_implemented(:target_attributes)
    def scope_of(_connection) = not_implemented(:scope_of)

    def status(_handle) = async_only(:status)
    def finish(_handle) = async_only(:finish)

    def find_operation(connection, _kind_config) = operations(connection).first
    def awaiting_operations?(_kind_config, _project) = false
    def action_blocker(_input_schema, _arguments = {}) = nil
    def operation_noun = "tool"
    def recorded_name(_kind_config, operation) = operation&.name
    def missing_config_item_names(error) = [ error.name ]

    def config_label(kind_config, project)
      connection = project && connection_for(kind_config, project)
      operation = connection && find_operation(connection, kind_config)
      operation ? label(connection, operation) : "the action's tool"
    end

    private

    def async_only(method)
      return not_implemented(method) if async?

      raise "#{self.class.name || 'Connectors::Transport'} is synchronous and has no ##{method}"
    end

    def not_implemented(method)
      raise NotImplementedError, "#{self.class.name || 'Connectors::Transport'}##{method} is not implemented"
    end
  end
end

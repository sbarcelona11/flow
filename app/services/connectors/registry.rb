# frozen_string_literal: true

module Connectors
  # Transports register by declaring `transport :key` in their class body and
  # are discovered from Transport descendants. The memo holds class objects, so
  # it is dropped on every code reload (config/initializers/connectors_registry.rb).
  module Registry
    class Unknown < StandardError; end
    class DuplicateTransportError < StandardError; end

    class << self
      def fetch(key)
        transports.fetch(key.to_s.to_sym) { raise Unknown, "Unknown connector transport: #{key}" }
      end

      def keys
        transports.keys
      end

      def for_target(target)
        transports.each_value.find { |klass| klass.transport_target == target.to_s } ||
          raise(Unknown, "Unknown connector target: #{target}")
      end

      def reset!
        @transports = nil
      end

      def build(classes)
        found = classes.select(&:transport_key)
        duplicate_keys = found.group_by(&:transport_key).select { |_, group| group.size > 1 }.keys
        raise DuplicateTransportError, "Duplicate transport keys: #{duplicate_keys.join(', ')}" if duplicate_keys.any?

        duplicate_targets = found.group_by(&:transport_target).select { |_, group| group.size > 1 }.keys
        raise DuplicateTransportError, "Duplicate transport targets: #{duplicate_targets.join(', ')}" if duplicate_targets.any?

        found.sort_by { |klass| [ klass.transport_position, klass.transport_key ] }.index_by(&:transport_key).freeze
      end

      def discovered_transports
        Rails.autoloaders.main.eager_load_namespace(Connectors) unless Rails.application.config.eager_load
        Transport.descendants.select(&:name)
      end

      private

      def transports
        @transports ||= build(discovered_transports)
      end
    end
  end
end

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
        transports.fetch(key.to_sym) { raise Unknown, "Unknown connector transport: #{key}" }
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

      private

      def transports
        @transports || build
      end

      def build
        Rails.autoloaders.main.eager_load_namespace(Connectors) unless Rails.application.config.eager_load

        found = Transport.descendants.select(&:transport_key)
        duplicates = found.group_by(&:transport_key).select { |_, group| group.size > 1 }.keys
        raise DuplicateTransportError, "Duplicate transport keys: #{duplicates.join(', ')}" if duplicates.any?

        @transports = found.sort_by(&:transport_key).index_by(&:transport_key).freeze
      end
    end
  end
end

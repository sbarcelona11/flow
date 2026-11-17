# frozen_string_literal: true

module Rest
  ImportResult = Struct.new(:base_url, :operations, :warnings, keyword_init: true) do
    def as_json(*) = { "base_url" => base_url, "operations" => operations.map(&:as_json), "warnings" => warnings }
    def to_json(*args) = as_json.to_json(*args)
  end

  class ImportResult
    TEXT_MAX = 2_000

    class Draft
      FIELDS = %i[name http_method path summary description input_schema effect].freeze

      attr_reader(*FIELDS)

      def initialize(**fields)
        FIELDS.each { |field| instance_variable_set(:"@#{field}", fields.fetch(field)) }
      end

      def to_h = FIELDS.index_with { |field| public_send(field) }
      def as_json(*) = to_h.stringify_keys
    end

    class Warnings
      MAX = 100

      def initialize
        @messages = []
        @seen = Set.new
        @more = 0
      end

      def <<(message)
        if @seen.include?(message) then nil
        elsif @messages.size < MAX
          @seen << message
          @messages << message
        else
          @more += 1
        end
        self
      end

      def to_a = @more.positive? ? @messages + [ "… and #{@more} more warnings." ] : @messages.dup
    end

    def self.text(value)
      value.is_a?(String) ? value.scrub[0, TEXT_MAX].presence : nil
    end

    class Names
      MAX = 64

      def initialize
        @taken = Set.new
      end

      def claim(preferred, fallback)
        base = snake(preferred).presence || snake(fallback).presence || "operation"
        base = "op_#{base}" unless base.match?(/\A[a-z]/)
        base = base[0, MAX].delete_suffix("_")
        name = base
        counter = 1
        while @taken.include?(name)
          counter += 1
          suffix = "_#{counter}"
          name = "#{base[0, MAX - suffix.length].delete_suffix('_')}#{suffix}"
        end
        @taken << name
        name
      end

      private

      def snake(value)
        value.to_s.scrub.underscore.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      end
    end
  end
end

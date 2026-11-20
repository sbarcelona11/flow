# frozen_string_literal: true

module Rest
  ImportResult = Struct.new(:base_url, :operations, :warnings, :servers, :auth_suggestions, keyword_init: true) do
    def initialize(servers: [], auth_suggestions: [], **fields)
      super(servers: servers, auth_suggestions: auth_suggestions, **fields)
    end

    def as_json(*)
      { "base_url" => base_url, "operations" => operations.map(&:as_json), "warnings" => warnings, "servers" => servers,
        "auth_suggestions" => auth_suggestions.map { |suggestion| suggestion.to_h.stringify_keys } }
    end

    def to_json(*args) = as_json.to_json(*args)
  end

  class ImportResult
    TEXT_MAX = 2_000
    MAX_SERVERS = 10
    MAX_SUGGESTIONS = 20
    TAG_MAX = 100

    class Draft
      REQUIRED = %i[name http_method path summary description input_schema effect].freeze
      FIELDS = (REQUIRED + %i[tag response_hint]).freeze

      attr_reader(*FIELDS)

      def initialize(tag: nil, response_hint: nil, **fields)
        REQUIRED.each { |field| instance_variable_set(:"@#{field}", fields.fetch(field)) }
        @tag = tag
        @response_hint = response_hint
      end

      def to_h = FIELDS.index_with { |field| public_send(field) }
      def as_json(*) = to_h.stringify_keys
    end

    # An auth suggestion names where a credential goes, never the credential: the importers only ever
    # see the name of a header or parameter, and only these three keys leave this class.
    class AuthSuggestions
      def initialize
        @items = []
      end

      def add(auth_type, header_name: nil, query_param: nil)
        return false if @items.size >= MAX_SUGGESTIONS

        suggestion = { auth_type: auth_type, header_name: header_name, query_param: query_param }
        @items << suggestion unless @items.include?(suggestion)
        true
      end

      def to_a = @items.dup
    end

    # Servers a connector could use: https, no credentials, public. Returns nil when the URL is unusable,
    # and the reason, which never repeats the URL's user information.
    def self.vet_server(url)
      uri = URI.parse(url.to_s)
      return [ nil, :scheme ] unless uri.is_a?(URI::HTTPS) && uri.host.present?
      return [ nil, :credentials ] if uri.userinfo || uri.query || uri.fragment

      errors = UrlSafetyValidator.errors_for(uri.to_s.chomp("/"), require_https: true)
      errors.any? ? [ nil, :unsafe ] : [ uri.to_s.chomp("/"), nil ]
    rescue URI::InvalidURIError, Regexp::TimeoutError
      [ nil, :scheme ]
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

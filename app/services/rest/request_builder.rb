# frozen_string_literal: true

module Rest
  class RequestBuilder
    class Invalid < StandardError; end

    class Request
      attr_reader :http_method, :uri, :headers, :body, :secrets, :config_item_names

      def initialize(http_method:, uri:, headers:, body:, secrets:, config_item_names:)
        @http_method = http_method
        @uri = uri
        @headers = headers
        @body = body
        @secrets = secrets
        @config_item_names = config_item_names
      end
    end

    BODYLESS = %w[GET].freeze

    def self.build(...) = new(...).build

    def initialize(operation:, arguments:, connector:, project:)
      @operation = operation
      @arguments = arguments.is_a?(Hash) ? arguments.deep_stringify_keys : {}
      @connector = connector
      @resolver = ConfigItems::ReferenceResolver.new(project: project)
      @headers = { "Accept" => "application/json" }.merge(connector.default_headers.to_h)
      @query = []
      @secrets = []
      @config_item_names = []
    end

    def build
      verb = @operation.http_method
      body = request_body(verb)
      @headers["Content-Type"] = "application/json" if body
      query = query_pairs
      apply_auth
      set_header("Accept-Encoding", "identity", secret: false)
      uri = vetted_uri(query + @query)
      Request.new(http_method: verb, uri: uri, headers: @headers, body: body, secrets: @secrets,
                  config_item_names: @config_item_names)
    end

    private

    def group(name)
      value = @arguments[name]
      return {} if value.nil?
      raise Invalid, "#{name} arguments must be an object" unless value.is_a?(Hash)

      value
    end

    def path
      values = group("path")
      @operation.path.to_s.gsub(ApiOperation::PLACEHOLDER) do
        name = Regexp.last_match(1)
        raise Invalid, "the path parameter #{name} is missing" unless values.key?(name)

        segment(name, values[name])
      end
    end

    def segment(name, value)
      raise Invalid, "the path parameter #{name} must be a single value" if value.is_a?(Hash) || value.is_a?(Array) || value.nil?

      text = value.to_s
      raise Invalid, "the path parameter #{name} can't be empty, . or .." if text.empty? || text.match?(/\A\.{1,2}\z/)

      ERB::Util.url_encode(text)
    end

    def query_pairs
      reserved = @connector.auth_type == "api_key_query" ? @connector.auth_config["query_param"] : nil
      group("query").filter_map do |key, value|
        next if value.nil? || key == reserved

        [ key, query_value(value) ]
      end
    end

    def query_value(value)
      case value
      when Array then value.map { |item| item.is_a?(Hash) || item.is_a?(Array) ? item.to_json : item.to_s }
      when Hash then value.to_json
      else value.to_s
      end
    end

    def request_body(verb)
      return nil if BODYLESS.include?(verb) || !@arguments.key?("body")

      JSON.generate(@arguments["body"])
    end

    def apply_auth
      config = @connector.auth_config.to_h
      case @connector.auth_type
      when "bearer" then set_header("Authorization", "Bearer #{item(config['config_item_name'])}")
      when "api_key_header" then api_key_header(config["header_name"].to_s, config["config_item_name"])
      when "api_key_query" then api_key_query(config["query_param"], item(config["config_item_name"]))
      when "basic" then basic(item(config["username_item"]), item(config["password_item"]))
      end
    end

    def item(name)
      value, = @resolver.resolve("config_item:#{name}")
      @config_item_names |= [ name ]
      secret(value)
      encoded_forms(value)
      value
    end

    # An API that echoes a credential often form- or URL-encodes it first.
    def encoded_forms(value)
      [ ERB::Util.url_encode(value), URI.encode_www_form_component(value) ].each { |form| secret(form) unless form == value }
    end

    def set_header(name, value, secret: true)
      @headers.delete_if { |key, _| key.casecmp?(name) }
      @headers[name] = value
      secret(value) if secret
    end

    def api_key_header(name, item_name)
      if name.match?(ApiConnector::TRANSPORT_HEADER) || name.match?(ApiConnector::FRAMING_HEADER)
        raise Invalid, "#{@connector.name} can't send its API key in the #{name} header"
      end

      set_header(name, item(item_name))
    end

    def api_key_query(param, value)
      @query << [ param, value ]
    end

    def basic(username, password)
      token = Base64.strict_encode64("#{username}:#{password}")
      secret(token)
      set_header("Authorization", "Basic #{token}")
    end

    def secret(value)
      @secrets |= [ value ] if value.present?
    end

    def vetted_uri(query)
      uri = URI.parse("#{@connector.base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query.any?
      raise Invalid, "#{@connector.name} must be called over https" unless uri.scheme == "https"
      raise Invalid, "#{@operation.name} would leave #{@connector.host}" unless same_origin?(uri)

      uri
    rescue URI::InvalidURIError
      raise Invalid, "#{@operation.name} does not make a valid URL"
    end

    def same_origin?(uri)
      base = URI.parse(@connector.base_url.to_s)
      uri.userinfo.nil? && uri.host.to_s.casecmp?(@connector.host) && @connector.host.present? && uri.port == base.port &&
        uri.path.start_with?(base.path)
    end
  end
end

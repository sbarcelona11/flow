# frozen_string_literal: true

module MCP
  class ToolCaller
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120
    REDACTED = "[redacted]"

    class AuthRequired < StandardError; end

    Result = Struct.new(:ok, :structured, :text, :error, :unknown, :config_item_names, keyword_init: true) do
      def ok? = ok == true
      def unknown? = unknown == true
    end

    def self.call(...) = new(...).call

    def initialize(server:, tool:, arguments:, user:)
      @server = server
      @tool = tool
      @arguments = arguments
      @user = user
      @secrets = []
      @config_item_names = []
    end

    def call
      return failure("stdio servers run in the agent container and cannot be called here") if @server.transport_stdio?
      return failure("#{@server.name} has no URL") if @server.url.blank?

      url_errors = UrlSafetyValidator.errors_for(@server.url, require_https: @server.oauth?)
      return failure("#{@server.name} URL #{url_errors.join(', ')}") if url_errors.any?

      headers = request_headers
      result_from(client(headers).call_tool(name: @tool, arguments: @arguments))
    rescue SafeHttp::UnsafeUrl => e
      failure("#{@server.name} URL #{e.message}")
    rescue ::MCP::Client::RequestHandlerError => e
      raise auth_required("#{@server.name} rejected the credentials") if unauthorized?(e)

      failure(e.message, unknown: timeout?(e))
    rescue ::MCP::Client::ServerError => e
      failure(e.message)
    rescue AuthRequired, ConfigItems::ReferenceResolver::Missing
      raise
    rescue StandardError, LoadError => e
      Rails.logger.warn("[ToolCaller] server=#{@server.id} tool=#{@tool}: #{e.class}: #{redact(e.message)}")
      failure("#{e.class}: #{e.message}")
    end

    private

    def client(headers)
      uri = URI.parse(@server.url)
      transport = ::MCP::Client::HTTP.new(url: @server.url, headers: headers) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.read_timeout = READ_TIMEOUT
        SafeHttp.pin_faraday!(faraday, uri)
      end
      ::MCP::Client.new(transport: transport)
    end

    def request_headers
      resolver = ConfigItems::ReferenceResolver.new(project: @server.scope)
      headers = (@server.headers || {}).to_h do |name, value|
        resolved, items = resolver.resolve(value)
        remember_secrets(value, resolved, *items.map(&:decrypted_value))
        @config_item_names |= items.map(&:name)
        [ name, resolved ]
      end
      token = access_token
      if token
        remember_secrets(token)
        headers["Authorization"] = "Bearer #{token}"
      end
      headers
    end

    def access_token
      return nil unless @server.oauth?
      raise auth_required("#{@server.name} acts as the run owner, and this run has none") if @server.credential_scope_per_user? && @user.nil?

      Oauth::TokenService.access_token_for(server: @server, user: @user) ||
        raise(auth_required("#{@server.name} is not connected"))
    rescue Oauth::ReauthRequired
      raise auth_required("#{@server.name} needs to be connected again")
    end

    def auth_required(message) = AuthRequired.new(message)

    def unauthorized?(error)
      error.error_type == :unauthorized || error.message.match?(/unauthorized/i)
    end

    def timeout?(error)
      error.original_error.is_a?(Faraday::TimeoutError)
    end

    def result_from(response)
      result = response.is_a?(Hash) ? response["result"].to_h : {}
      text = Array(result["content"]).filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join("\n")
      structured = redact_deep(result["structuredContent"])
      return failure(text.presence || "#{@tool} reported an error") if result["isError"] == true

      Result.new(ok: true, structured: structured, text: redact(text), unknown: false, config_item_names: @config_item_names)
    end

    def failure(message, unknown: false)
      Result.new(ok: false, error: redact(message.to_s), text: nil, structured: nil, unknown: unknown,
                 config_item_names: @config_item_names)
    end

    def remember_secrets(*values)
      @secrets = (@secrets + values.map(&:to_s)).reject(&:blank?).uniq.sort_by { |v| -v.length }
    end

    def redact(text)
      return text if text.nil? || @secrets.empty?

      @secrets.reduce(text.to_s) { |scrubbed, secret| scrubbed.gsub(secret, REDACTED) }
    end

    def redact_deep(value)
      case value
      when Hash then value.transform_values { |v| redact_deep(v) }
      when Array then value.map { |v| redact_deep(v) }
      when String then redact(value)
      else value
      end
    end
  end
end

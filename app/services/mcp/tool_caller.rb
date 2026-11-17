# frozen_string_literal: true

module MCP
  class ToolCaller
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120
    CREDENTIAL_HEADER = /\A(?:authorization|proxy-authorization|cookie)\z|(?:key|token|secret)\z/i
    NOT_SENT = [ Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                 Errno::EADDRNOTAVAIL, SocketError ].freeze

    class AuthRequired < StandardError; end

    Result = Struct.new(:ok, :structured, :text, :error, :unknown, :config_item_names, :redactor, keyword_init: true) do
      def ok? = ok == true
      def unknown? = unknown == true
    end

    def self.call(...) = new(...).call

    def initialize(server:, tool:, arguments:, user:)
      @server = server
      @tool = tool
      @arguments = arguments
      @user = user
      @redactor = Actions::SecretRedactor.new
      @config_item_names = []
    end

    def call
      return failure("stdio servers run in the agent container and cannot be called here") if @server.transport_stdio?
      return failure("#{@server.name} has no URL") if @server.url.blank?

      url_errors = UrlSafetyValidator.errors_for(@server.url, require_https: @server.oauth?)
      return failure("#{@server.name} URL #{url_errors.join(', ')}") if url_errors.any?

      client = build_client(request_headers)
      handshake(client) || call_tool(client)
    rescue SafeHttp::UnsafeUrl => e
      failure("#{@server.name} URL #{e.message}")
    end

    private

    def build_client(headers)
      uri = URI.parse(@server.url)
      transport = ::MCP::Client::HTTP.new(url: @server.url, headers: headers) do |faraday|
        faraday.options.open_timeout = OPEN_TIMEOUT
        faraday.options.read_timeout = READ_TIMEOUT
        SafeHttp.pin_faraday!(faraday, uri)
      end
      ::MCP::Client.new(transport: transport)
    end

    def handshake(client)
      client.connect(mode: :legacy)
      nil
    rescue ::MCP::Client::RequestHandlerError => e
      raise_if_unauthorized!(e)
      failure(e.message)
    rescue StandardError, LoadError => e
      unexpected(e, unknown: false)
    end

    def call_tool(client)
      result_from(client.call_tool(name: @tool, arguments: @arguments))
    rescue ::MCP::Client::RequestHandlerError => e
      raise_if_unauthorized!(e)
      failure(e.message, unknown: !known_not_done?(e.original_error))
    rescue ::MCP::Client::ServerError => e
      failure(e.message)
    rescue StandardError, LoadError => e
      unexpected(e, unknown: true)
    end

    def raise_if_unauthorized!(error)
      raise AuthRequired, "#{@server.name} rejected the credentials" if error.error_type == :unauthorized
    end

    def known_not_done?(error)
      case error
      when Faraday::ClientError then true
      when Faraday::SSLError then error.message.start_with?("SSL_connect")
      when Faraday::ConnectionFailed then NOT_SENT.any? { |klass| error.wrapped_exception.is_a?(klass) }
      else false
      end
    end

    def unexpected(error, unknown:)
      Rails.logger.warn("[ToolCaller] server=#{@server.id} tool=#{@tool}: #{error.class}: #{redact(error.message)}")
      failure("#{error.class} while calling #{@server.name}", unknown: unknown)
    end

    def request_headers
      resolver = ConfigItems::ReferenceResolver.new(project: @server.scope)
      headers = (@server.headers || {}).to_h do |name, value|
        resolved, items = resolver.resolve(value)
        items.select(&:secret?).each { |item| remember_secret(item.decrypted_value) }
        remember_literal(resolved) if @server.auth_type_static? || name.to_s.match?(CREDENTIAL_HEADER)
        @config_item_names |= items.map(&:name)
        [ name, resolved ]
      end
      token = access_token
      if token
        remember_secret(token)
        headers["Authorization"] = "Bearer #{token}"
      end
      headers
    end

    def access_token
      return nil unless @server.oauth?
      raise AuthRequired, "#{@server.name} acts as the run owner, and this run has none" if @server.credential_scope_per_user? && @user.nil?

      Oauth::TokenService.access_token_for(server: @server, user: @user) ||
        raise(AuthRequired, "#{@server.name} is not connected")
    rescue Oauth::ReauthRequired
      raise AuthRequired, "#{@server.name} needs to be connected again"
    end

    def result_from(response)
      result = response.is_a?(Hash) ? response["result"] : nil
      return failure("#{@server.name} answered #{@tool} without a result", unknown: true) unless result.is_a?(Hash)

      text = Array(result["content"]).filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join("\n")
      return failure(text.presence || "#{@tool} reported an error") if result["isError"] == true

      Result.new(ok: true, structured: @redactor.redact(result["structuredContent"]), text: redact(text), unknown: false,
                 config_item_names: @config_item_names, redactor: @redactor.method(:redact_text))
    end

    def failure(message, unknown: false)
      Result.new(ok: false, error: redact(message.to_s), text: nil, structured: nil, unknown: unknown,
                 config_item_names: @config_item_names, redactor: @redactor.method(:redact_text))
    end

    def remember_literal(value) = @redactor.add_literal(value)

    def remember_secret(value) = @redactor.add(value)

    def redact(text) = @redactor.redact_text(text)
  end
end

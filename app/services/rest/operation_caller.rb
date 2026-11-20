# frozen_string_literal: true

module Rest
  class OperationCaller
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 120
    MAX_BYTES = Step::ACTION_OUTPUT_MAX_BYTES
    ERROR_EXCERPT = 500
    NOT_SENT = [ Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                 Errno::EADDRNOTAVAIL, SocketError ].freeze
    VERBS = { "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put,
              "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete }.freeze

    class TooLarge < StandardError; end
    class DeadlineExceeded < StandardError; end

    Result = Struct.new(:ok, :structured, :text, :error, :unknown, :status, :config_item_names, :redactor,
                        keyword_init: true) do
      def ok? = ok == true
      def unknown? = unknown == true
    end

    def self.call(...) = new(...).call

    # deadline: total seconds for the whole exchange. Net::HTTP's read_timeout bounds each socket read only, so a
    # server that drips a byte at a time would otherwise hold the caller until MAX_BYTES; runs keep no deadline.
    def initialize(operation:, arguments:, project:, read_timeout: READ_TIMEOUT, deadline: nil)
      @read_timeout = read_timeout
      @deadline = deadline
      @operation = operation
      @connector = operation.api_connector
      @arguments = arguments
      @project = project
      @verb = operation.http_method
      @redactor = Actions::SecretRedactor.new
      @config_item_names = []
    end

    def call
      return failure("#{@operation.name} belongs to another project") unless own_connector?

      url_errors = UrlSafetyValidator.errors_for(@connector.base_url, require_https: true)
      return failure("#{@connector.name} base URL #{url_errors.join(', ')}") if url_errors.any?

      request = RequestBuilder.build(operation: @operation, arguments: @arguments, connector: @connector, project: @project)
      @config_item_names = request.config_item_names
      request.secrets.each { |secret| @redactor.add(secret) }
      @redactor.add(request.uri.to_s) if @connector.auth_type == "api_key_query"
      send_request(request)
    rescue RequestBuilder::Invalid => e
      failure(e.message)
    end

    private

    def own_connector?
      @connector.present? && @connector.scope_type == "Project" && @connector.scope_id == @project.id
    end

    def send_request(request)
      url_errors = UrlSafetyValidator.errors_for(request.uri.to_s, require_https: true)
      return failure("#{@connector.name} URL #{url_errors.join(', ')}") if url_errors.any?

      status, content_type, body = perform(request)
      log("status=#{status}")
      classify(status, content_type, body)
    rescue SafeHttp::UnsafeUrl => e
      failure("#{@connector.name} URL #{e.message}")
    rescue RequestBuilder::Invalid => e
      failure(e.message)
    rescue DeadlineExceeded
      failure("#{@connector.name} took longer than #{@deadline.to_i} seconds to answer #{described}", unknown: @verb != "GET", status: @status)
    rescue TooLarge
      failure("#{@connector.name} answered with more than #{MAX_BYTES / 1.megabyte} MB", unknown: @verb != "GET",
                                                                                         status: @status)
    rescue StandardError => e
      unexpected(e)
    end

    def perform(request)
      net = net_request(request)
      http = SafeHttp.http_for(request.uri, open_timeout: OPEN_TIMEOUT, read_timeout: @read_timeout)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.max_retries = 0
      body = +""
      content_type = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      http.start do |connection|
        @connected = true
        connection.request(net) do |response|
          @status = response.code.to_i
          content_type = response["Content-Type"]
          response.read_body do |chunk|
            body << chunk
            raise TooLarge if body.bytesize > MAX_BYTES

            check_deadline!(started)
          end
        end
      end
      check_deadline!(started)
      [ @status, content_type, body.force_encoding(Encoding::UTF_8).scrub ]
    end

    def check_deadline!(started)
      raise DeadlineExceeded if @deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > @deadline
    end

    def net_request(request)
      net = VERBS.fetch(request.http_method).new(request.uri, request.headers)
      net.body = request.body if request.body
      net
    rescue ArgumentError
      raise RequestBuilder::Invalid, "Could not build #{described}: a header value contains a line break."
    end

    def classify(status, content_type, body)
      case status
      when 200..299 then success(status, content_type, body)
      when 300..399
        failure("#{@connector.name} redirected #{described} (#{status}); redirects are not followed",
                unknown: @verb != "GET", status: status)
      when 400..499 then failure(answered(status, body), status: status)
      else failure(answered(status, body), unknown: true, status: status)
      end
    end

    def success(status, content_type, body)
      structured = json?(content_type) ? parse(body) : nil
      text = structured.nil? ? @redactor.redact_text(body) : nil
      Result.new(ok: true, structured: @redactor.redact(structured), text: text, error: nil, unknown: false, status: status,
                 config_item_names: @config_item_names, redactor: @redactor.method(:redact_text))
    end

    def json?(content_type)
      content_type.to_s.split(";").first.to_s.strip.match?(%r{\Aapplication/(?:[\w.-]+\+)?json\z}i)
    end

    def parse(body)
      body.blank? ? nil : JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def answered(status, body)
      excerpt = @redactor.redact_text(body.to_s).strip[0, ERROR_EXCERPT]
      [ "#{@connector.name} answered #{status} to #{described}", excerpt.presence ].compact.join(": ")
    end

    def described = "#{@verb} #{@operation.path}"

    def unexpected(error)
      log("#{error.class}: #{@redactor.redact_text(error.message)}")
      failure("#{@connector.name} could not complete #{described} (#{error.class.name})", unknown: sent?(error))
    end

    def sent?(error)
      return false if NOT_SENT.any? { |klass| error.is_a?(klass) }
      return false if error.is_a?(OpenSSL::SSL::SSLError) && error.message.start_with?("SSL_connect")

      @connected == true
    end

    def log(message)
      Rails.logger.info("[Rest::OperationCaller] operation=#{@operation.id} #{described} #{message}")
    end

    def failure(message, unknown: false, status: nil)
      Result.new(ok: false, structured: nil, text: nil, error: @redactor.redact_text(message.to_s), unknown: unknown,
                 status: status, config_item_names: @config_item_names, redactor: @redactor.method(:redact_text))
    end
  end
end

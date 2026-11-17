# frozen_string_literal: true

require "shellwords"

module Rest
  class CurlImporter
    MAX_LENGTH = 64.kilobytes
    MAX_NESTING = 32
    CREDENTIAL_HEADER = /\A(?:authorization|proxy-authorization|cookie|apikey|token|secret|.*[-_](?:key|token|secret|password))\z/i
    CREDENTIAL_PARAM = /\A(?:api[-_]?key|key|token|access[-_]?token|secret|client[-_]secret|password|signature|sig|.*[-_](?:key|token|secret))\z/i
    SILENT_HEADERS = %w[accept accept-encoding accept-language user-agent content-length host connection].freeze
    OPTIONS = {
      "-X" => :method, "--request" => :method,
      "-H" => :header, "--header" => :header,
      "-d" => :data, "--data" => :data, "--data-raw" => :data, "--data-binary" => :data, "--data-ascii" => :data,
      "--data-urlencode" => :data, "--json" => :json,
      "--url" => :url,
      "-u" => :user, "--user" => :user,
      "-b" => :cookie, "--cookie" => :cookie, "--oauth2-bearer" => :bearer,
      "-F" => :form, "--form" => :form,
      "-G" => :get, "--get" => :get
    }.freeze
    IGNORED_WITH_VALUE = %w[
      -A --user-agent -e --referer -o --output -m --max-time --connect-timeout --retry --retry-delay -w --write-out
      -x --proxy -U --proxy-user -E --cert --key --cacert --capath -r --range --resolve --connect-to -c --cookie-jar
      --max-redirs --limit-rate -T --upload-file -K --config
    ].freeze
    QUIET_FLAGS = "sSLkivfgNG#"
    VALUE_OPTIONS = OPTIONS.reject { |_, kind| kind == :get }.keys.freeze
    ATTACHED_SHORT = (VALUE_OPTIONS + IGNORED_WITH_VALUE).select { |flag| flag.match?(/\A-[^-]\z/) }.freeze

    def self.parse(command) = new(command).parse

    def initialize(command)
      text = command.to_s
      raise ImportError, "This cURL command is too long to import." if text.bytesize > MAX_LENGTH

      @tokens = tokenize(text)
      @warnings = ImportResult::Warnings.new
      @headers = []
      @data = []
    end

    def parse
      read_options
      uri = target_uri
      query = query_properties(uri)
      method = verb
      body = body_schema(method)
      path = uri.path.presence || "/"
      errors = ApiOperation.path_errors(path)
      raise ImportError, "The URL path can't be imported: it #{errors.first}." if errors.any?

      draft = ImportResult::Draft.new(
        name: ImportResult::Names.new.claim(nil, "#{method.downcase} #{path}"), http_method: method, path: path,
        summary: nil, description: nil, input_schema: input_schema(query, body), effect: ApiOperation.minimum_effect_for(method)
      )
      ImportResult.new(base_url: base_url(uri), operations: [ draft ], warnings: @warnings.to_a)
    end

    private

    def tokenize(text)
      tokens = Shellwords.split(text.scrub.gsub(/\\\r?\n/, " "))
      raise ImportError, "Paste a command that starts with curl." unless tokens.first.to_s.split("/").last == "curl"

      tokens.drop(1)
    rescue ArgumentError
      raise ImportError, "This cURL command has an unmatched quote."
    end

    def read_options
      tokens = @tokens.dup
      while (token = tokens.shift)
        flag, value = split_option(token)
        kind = OPTIONS[flag]
        if kind && kind != :get
          value ||= tokens.shift
          raise ImportError, "The option #{flag} is missing its value." if value.nil?
        end
        apply(kind, flag, value, tokens)
      end
    end

    def split_option(token)
      return [ token, nil ] unless token.start_with?("-")
      return token.split("=", 2) if token.start_with?("--")

      short = token[0, 2]
      ATTACHED_SHORT.include?(short) && token.length > 2 ? [ short, token[2..] ] : [ token, nil ]
    end

    def apply(kind, flag, value, tokens)
      case kind
      when :method then @method = value.upcase
      when :header then @headers << value
      when :data then @data << value
      when :json
        @data << value
        @headers << "Content-Type: application/json"
      when :url then @url ||= value
      when :get then @get = true
      when :user
        note("The command signs in with -u (basic auth); set the connector's authentication to basic with Config Items " \
             "for the user name and password.")
      when :cookie then credential("Cookie")
      when :bearer then credential("Authorization")
      when :form then note("Multipart form data (-F) is not imported; only JSON bodies can be imported.")
      else other(flag, value, tokens)
      end
    end

    def other(flag, value, tokens)
      if !flag.start_with?("-") || flag == "-"
        @url ? note("An extra argument in the command was ignored.") : @url = flag
      elsif IGNORED_WITH_VALUE.include?(flag)
        tokens.shift if value.nil?
      elsif flag.match?(/\A-[#{Regexp.escape(QUIET_FLAGS)}]+\z/o)
        @get = true if flag.include?("G")
      elsif !%w[--silent --show-error --location --insecure --include --verbose --compressed --fail --fail-with-body
                --globoff --no-buffer].include?(flag)
        note("The option #{option_name(flag)} is not imported.")
      end
    end

    def option_name(flag)
      flag.start_with?("--") ? flag[0, 40] : flag[0, 2]
    end

    def target_uri
      raise ImportError, "This cURL command has no URL." if @url.blank?

      url = @url.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? @url : "http://#{@url}"
      uri = URI.parse(url)
      raise ImportError, "The URL in this cURL command must be an http or https URL." unless uri.is_a?(URI::HTTP) && uri.host.present?

      if uri.userinfo
        note("The URL carries a user name and password, which were left out; set the connector's authentication to " \
             "basic with Config Items instead.")
      end
      uri
    rescue URI::InvalidURIError
      raise ImportError, "The URL in this cURL command is not a valid URL."
    end

    def base_url(uri)
      return URI::HTTPS.build(host: uri.host, port: uri.port).to_s if uri.scheme == "https"

      note("The URL uses #{uri.scheme}; a connector needs https, so enter its https base URL yourself.")
      nil
    end

    def verb
      method = @method || (@data.any? && !@get ? "POST" : "GET")
      return method if ApiOperation::METHODS.include?(method)

      raise ImportError, "#{method[0, 20]} requests can't be imported; use GET, POST, PUT, PATCH or DELETE."
    end

    def query_properties(uri)
      pairs = decode_form(uri.query)
      pairs += decode_form(@data.join("&")) if @get
      pairs.each_with_object({}) do |(name, _), properties|
        if name.match?(CREDENTIAL_PARAM)
          note("The query parameter #{name[0, 100]} looks like a credential and was left out. " \
               "Choose a Config Item for #{name[0, 100]} on the connector.")
        elsif name.present?
          properties[name] = { "type" => "string" }
        end
      end
    end

    def decode_form(text)
      text.present? ? URI.decode_www_form(text) : []
    rescue ArgumentError
      []
    end

    def body_schema(method)
      content_json = false
      @headers.each do |header|
        name, separator, = header.partition(":")
        name = name.strip
        if separator.empty? || !name.match?(ApiConnector::HEADER_NAME)
          note("A header without a name was not imported.")
        elsif name.match?(CREDENTIAL_HEADER) then credential(name)
        elsif name.casecmp?("content-type") then content_json = header.split(":", 2).last.to_s.match?(/json/i)
        elsif SILENT_HEADERS.exclude?(name.downcase)
          note("The header #{name[0, 100]} is not imported; add it to the connector's default headers if every call needs it.")
        end
      end
      return nil if @get || @data.empty?

      json_body(method, content_json)
    end

    def json_body(method, content_json)
      return note("Data read from a file (@…) is not imported.") if @data.any? { |data| data.start_with?("@") }

      parsed = parse_json(@data.join("&"))
      if parsed.nil?
        note("The request body is not JSON, so it was left out; only JSON bodies can be imported.") unless content_json
        note("The request body is not valid JSON, so it was left out.") if content_json
        nil
      elsif !parsed.is_a?(Hash)
        note("The request body is not a JSON object, so it was left out; only a JSON object body can be imported.")
      elsif method == "GET"
        note("A GET request sends no body, so the body was left out.")
      else
        infer(parsed)
      end
    end

    def parse_json(text)
      JSON.parse(text, max_nesting: MAX_NESTING)
    rescue JSON::ParserError
      nil
    end

    def infer(value)
      case value
      when Hash
        properties = value.to_h { |key, child| [ key.to_s, infer(child) ] }
        properties.empty? ? { "type" => "object" } : { "type" => "object", "properties" => properties }
      when Array then value.empty? ? { "type" => "array" } : { "type" => "array", "items" => infer(value.first) }
      when String then { "type" => "string" }
      when Integer then { "type" => "integer" }
      when Float then { "type" => "number" }
      when true, false then { "type" => "boolean" }
      else {}
      end
    end

    def input_schema(query, body)
      properties = {}
      properties["query"] = { "type" => "object", "properties" => query } if query.any?
      properties["body"] = body if body
      schema = { "type" => "object", "properties" => properties }
      return schema if body.nil? || SchemaHygiene.errors_for(schema).empty?

      note("The JSON body is too large or nests too deeply to import, so it was left out.")
      input_schema(query, nil)
    end

    def credential(name)
      note("The command sends #{name[0, 100]}, which was left out. Choose a Config Item for #{name[0, 100]} on the connector.")
    end

    def note(message)
      @warnings << message
      nil
    end
  end
end

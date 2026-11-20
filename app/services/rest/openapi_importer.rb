# frozen_string_literal: true

require "net/http"

module Rest
  class OpenapiImporter
    MAX_BYTES = 2.megabytes
    MAX_OPERATIONS = 500
    MAX_NESTING = 64
    NODE_BUDGET = 200_000
    REF_DEPTH = 16
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    FETCH_DEADLINE = 60
    MAX_PARAMETERS = 200
    VERBS = %w[get put post delete patch head options trace].freeze
    JSON_MEDIA = %r{\Aapplication/(?:[\w.-]+\+)?json\z}i
    NAME_KEYED = %w[properties patternProperties dependentSchemas].freeze
    DROPPED_KEYS = (SchemaHygiene::FORBIDDEN_KEYS + %w[$id $schema $anchor $comment]).freeze
    TEXT_KEYS = %w[description title summary].freeze
    LABEL_MAX = 200
    MAX_SERVER_ENTRIES = 50
    MAX_SCHEMES = 50

    TOO_LARGE = "This document is larger than 2 MB."
    EXPANDS = "This document expands to more than the import limit. Import a smaller part of the document."
    TOO_DEEP = "This document nests too deeply to import."
    UNSUPPORTED = "Only OpenAPI 3.0 and 3.1 documents can be imported."
    ALIASES = "This document uses YAML aliases (*name), which the import does not accept."

    def self.from_text(text) = new(parse(text)).import

    def self.from_url(url) = from_text(fetch(url))

    def self.parse(text)
      text = text.to_s
      raise ImportError, TOO_LARGE if text.bytesize > MAX_BYTES

      text = text.dup.force_encoding(Encoding::UTF_8)
      raise ImportError, "This document is not UTF-8 text." unless text.valid_encoding?

      text.lstrip.start_with?("{", "[") ? parse_json(text) : parse_yaml(text)
    end

    def self.parse_json(text)
      JSON.parse(text, max_nesting: MAX_NESTING)
    rescue JSON::NestingError
      raise ImportError, TOO_DEEP
    rescue JSON::ParserError
      raise ImportError, "This document is not valid JSON or YAML."
    end

    def self.parse_yaml(text)
      check_yaml_tree(Psych.parse(text))
      plain(Psych.safe_load(text, permitted_classes: [ Date, Time ], permitted_symbols: [], aliases: false))
    rescue Psych::SyntaxError => e
      raise ImportError, "This document is not valid JSON or YAML (line #{e.line}, column #{e.column})."
    rescue Psych::DisallowedClass
      raise ImportError, "This document uses a YAML type the import does not accept; only plain strings, numbers, " \
                         "booleans, dates, lists and maps are allowed."
    end

    def self.plain(value)
      case value
      when Hash then value.to_h { |key, child| [ plain(key).to_s, plain(child) ] }
      when Array then value.map { |child| plain(child) }
      when Date, Time then value.iso8601
      else value
      end
    end

    def self.check_yaml_tree(tree)
      stack = tree ? [ [ tree, 0 ] ] : []
      while (entry = stack.pop)
        node, depth = entry
        raise ImportError, ALIASES if node.is_a?(Psych::Nodes::Alias)
        raise ImportError, TOO_DEEP if depth > MAX_NESTING

        Array(node.children).each { |child| stack << [ child, depth + 1 ] }
      end
    end

    def self.fetch(url)
      uri = vetted_uri(url)
      http = SafeHttp.http_for(uri, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.max_retries = 0
      body = +""
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      request = Net::HTTP::Get.new(uri, "Accept" => "application/json, application/yaml, text/yaml, */*;q=0.1",
                                        "Accept-Encoding" => "identity")
      http.start do |connection|
        connection.request(request) do |response|
          check_status(response.code.to_i)
          response.read_body do |chunk|
            body << chunk
            raise ImportError, TOO_LARGE if body.bytesize > MAX_BYTES
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > FETCH_DEADLINE
              raise ImportError, "The document took longer than #{FETCH_DEADLINE} seconds to download."
            end
          end
        end
      end
      body
    rescue SafeHttp::UnsafeUrl => e
      raise ImportError, "The document URL #{e.message}."
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, SocketError, SystemCallError, IOError,
           OpenSSL::SSL::SSLError, Zlib::Error => e
      raise ImportError, "The document could not be fetched (#{e.class.name.demodulize})."
    end

    def self.vetted_uri(url)
      uri = URI.parse(url.to_s.strip)
      raise ImportError, "The document URL must use https." unless uri.is_a?(URI::HTTPS) && uri.host.present?
      raise ImportError, "The document URL can't include a user name or password." if uri.userinfo

      errors = UrlSafetyValidator.errors_for(uri.to_s, require_https: true)
      raise ImportError, "The document URL #{errors.to_sentence}." if errors.any?

      uri
    rescue URI::InvalidURIError
      raise ImportError, "The document URL is not a valid URL."
    end

    def self.check_status(status)
      return if status.between?(200, 299)
      raise ImportError, "The document URL redirected (#{status}); enter the document's final URL." if status.between?(300, 399)

      raise ImportError, "The document URL answered #{status}."
    end

    private_class_method :parse_json, :parse_yaml, :plain, :check_yaml_tree, :fetch, :vetted_uri, :check_status

    def initialize(document)
      @document = document
      @warnings = ImportResult::Warnings.new
      @budget = NODE_BUDGET
      @names = ImportResult::Names.new
      @cycles = Set.new
    end

    def import
      raise ImportError, UNSUPPORTED unless @document.is_a?(Hash) && @document["openapi"].to_s.match?(/\A3\.[01](?:\.|\z)/)

      items = path_items
      count = items.sum { |_, item| operations_of(item).size }
      if count > MAX_OPERATIONS
        raise ImportError, "This document lists #{count} operations; the import takes at most #{MAX_OPERATIONS}."
      end

      base_url = server_url
      drafts = items.flat_map do |path, item|
        operations_of(item).filter_map { |verb, operation| draft(path, verb, operation, item["parameters"]) }
      end
      servers = server_list
      suggestions = auth_suggestions
      ImportResult.new(base_url: base_url, operations: drafts, warnings: @warnings.to_a, servers: servers,
                       auth_suggestions: suggestions.to_a)
    end

    private

    def path_items
      paths = @document["paths"]
      return [] unless paths.is_a?(Hash)

      paths.filter_map do |path, item|
        spend!
        item = deref(item)
        [ path.to_s, item ] if item.is_a?(Hash)
      end
    end

    def operations_of(item)
      item.select { |verb, operation| VERBS.include?(verb.to_s) && operation.is_a?(Hash) }
    end

    def expanded_server(server)
      return nil unless server.is_a?(Hash) && server["url"].is_a?(String)

      variables = server["variables"].is_a?(Hash) ? server["variables"] : {}
      server["url"].gsub(/\{([^{}]*)\}/) do
        variable = variables[Regexp.last_match(1)]
        variable.is_a?(Hash) ? variable["default"].to_s : ""
      end.chomp("/")
    end

    # Every https server a connector could use. The first one is already explained by server_url when it
    # is not https or carries credentials, so only the others get that warning.
    def server_list
      raw = @document["servers"].is_a?(Array) ? @document["servers"].first(MAX_SERVER_ENTRIES) : []
      raw.each_with_index.with_object([]) do |(server, index), kept|
        url = expanded_server(server)
        next if url.nil? || kept.size >= ImportResult::MAX_SERVERS

        vetted, reason = userinfo?(url) ? [ nil, :credentials ] : ImportResult.vet_server(url)
        if vetted then kept << vetted
        elsif reason == :unsafe then note("The server #{server_host(url)} points to a private or internal address and was left out.")
        elsif index.positive? && reason == :credentials then note("A server URL includes a user name or password; it was left out.")
        elsif index.positive? then note("The server #{server_host(url)} is not an https URL and was left out.")
        end
      end.uniq
    end

    def server_host(url)
      host = URI.parse(url).host
      host.present? ? label_text(host, 100) : "URL"
    rescue URI::InvalidURIError
      "URL"
    end

    def auth_suggestions
      suggestions = ImportResult::AuthSuggestions.new
      schemes = @document.dig("components", "securitySchemes") if @document["components"].is_a?(Hash)
      return suggestions unless schemes.is_a?(Hash)

      schemes.first(MAX_SCHEMES).each do |name, scheme|
        spend!
        scheme = deref(scheme)
        suggest_auth(suggestions, label_text(name, 60), scheme) if scheme.is_a?(Hash)
      end
      suggestions
    end

    def suggest_auth(suggestions, name, scheme)
      case scheme["type"].to_s.downcase
      when "http" then suggest_http(suggestions, name, scheme["scheme"].to_s.downcase)
      when "apikey" then suggest_api_key(suggestions, name, scheme)
      when "oauth2", "openidconnect"
        note("The security scheme #{name} (#{label_text(scheme['type'], 30)}) is not supported yet; set up authentication by hand.")
      end
    end

    def suggest_http(suggestions, name, http_scheme)
      case http_scheme
      when "bearer" then suggestions.add("bearer")
      when "basic" then suggestions.add("basic")
      else note("The security scheme #{name} uses #{label_text(http_scheme, 30)} authentication, which is not supported yet.")
      end
    end

    def suggest_api_key(suggestions, name, scheme)
      key = scheme["name"].to_s
      case scheme["in"].to_s
      when "header"
        if !key.match?(ApiConnector::HEADER_NAME) || key.length > 100
          note("The security scheme #{name} names a header that is not a usable header name.")
        elsif key.match?(ApiConnector::TRANSPORT_HEADER) || key.match?(ApiConnector::FRAMING_HEADER)
          note("The security scheme #{name} names the header #{key}, which can't carry an API key.")
        else
          suggestions.add("api_key_header", header_name: key)
        end
      when "query"
        if key.match?(ApiConnector::QUERY_PARAM) && key.length <= 100
          suggestions.add("api_key_query", query_param: key)
        else
          note("The security scheme #{name} names a query parameter that is not a usable name.")
        end
      else note("The security scheme #{name} sends its key in a cookie, which is not supported.")
      end
    end

    def server_url
      server = @document["servers"].is_a?(Array) ? @document["servers"].first : nil
      url = expanded_server(server)
      return nil if url.nil?

      if userinfo?(url)
        note("The first server URL includes a user name or password; it was not used.")
        return nil
      end
      return url if https_base?(url)

      note("The first server URL is not an https URL; enter the base URL yourself.")
      nil
    end

    def userinfo?(url)
      scheme = %r{\A[a-z][a-z0-9+.-]*://}i
      return url.include?("@") unless url.match?(scheme)

      url.sub(scheme, "").split(%r{[/\\?#]}, 2).first.to_s.include?("@")
    end

    def https_base?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def draft(path, verb, operation, shared_parameters)
      method = verb.to_s.upcase
      label = "#{method} #{label_text(path)}"
      return skip(label, "only GET, POST, PUT, PATCH and DELETE can be imported") if ApiOperation::METHODS.exclude?(method)

      path_errors = ApiOperation.path_errors(path)
      return skip(label, "its path #{path_errors.first}") if path_errors.any?

      listed = [ shared_parameters, operation["parameters"] ].sum { |list| list.is_a?(Array) ? list.size : 0 }
      return skip(label, "it lists more than #{MAX_PARAMETERS} parameters") if listed > MAX_PARAMETERS

      schema = catch(:too_deep) { input_schema(path, operation, shared_parameters, label) }
      return skip(label, "its input schema nests deeper than #{SchemaHygiene::MAX_DEPTH} levels") if schema.nil?

      errors = SchemaHygiene.errors_for(schema)
      return skip(label, "its input schema #{errors.to_sentence}") if errors.any?

      ImportResult::Draft.new(
        name: @names.claim(operation["operationId"], "#{method.downcase} #{path}"), http_method: method, path: path,
        summary: ImportResult.text(operation["summary"]), description: ImportResult.text(operation["description"]),
        input_schema: schema, effect: ApiOperation.minimum_effect_for(method), tag: tag_of(operation),
        response_hint: response_hint(operation)
      )
    end

    def tag_of(operation)
      tag = Array(operation["tags"]).first
      tag.is_a?(String) ? label_text(tag, ImportResult::TAG_MAX).strip.presence : nil
    end

    def response_hint(operation)
      responses = deref(operation["responses"])
      return nil unless responses.is_a?(Hash)

      success = responses.keys.map(&:to_s).grep(/\A2\d\d\z/).min
      response = success && deref(responses[success])
      content = response.is_a?(Hash) ? response["content"] : nil
      return nil unless content.is_a?(Hash)

      types = content.keys.map { |type| type.to_s.split(";").first.to_s.strip }
      if types.any? { |type| type.match?(JSON_MEDIA) } then "json"
      elsif types.any? { |type| type.downcase.start_with?("text/") } then "text"
      end
    end

    def skip(label, reason)
      note("#{label} is skipped: #{reason}.")
      nil
    end

    def input_schema(path, operation, shared_parameters, label)
      groups = { "path" => object_group, "query" => object_group }
      required = []
      placeholders = path.scan(ApiOperation::PLACEHOLDER).flatten.uniq

      parameters(shared_parameters, operation["parameters"]).each do |parameter|
        spend!
        name = parameter["name"]
        case parameter["in"]
        when "path"
          add_property(groups["path"], name, parameter_schema(parameter, label, string_default: true), required: true) if placeholders.include?(name)
        when "query"
          add_property(groups["query"], name, parameter_schema(parameter, label), required: parameter["required"] == true)
        when "header", "cookie"
          note("#{label} drops the #{parameter['in']} parameter #{label_text(name)}; set fixed headers on the connector instead.")
        end
      end
      placeholders.each do |name|
        add_property(groups["path"], name, { "type" => "string" }, required: true) unless groups["path"]["properties"].key?(name)
      end

      body, body_required = request_body(operation["requestBody"], label)
      groups["body"] = body if body

      properties = groups.select { |name, group| name == "body" || group["properties"].any? }
      required << "path" if placeholders.any?
      required << "query" if groups["query"]["required"]&.any?
      required << "body" if body && body_required
      { "type" => "object", "properties" => properties }.merge(required.any? ? { "required" => required } : {})
    end

    def object_group = { "type" => "object", "properties" => {} }

    def add_property(group, name, schema, required:)
      group["properties"][name] = schema
      (group["required"] ||= []) << name if required
    end

    def parameters(shared, own)
      merged = {}
      [ shared, own ].each do |list|
        next unless list.is_a?(Array)

        list.each do |parameter|
          spend!
          parameter = deref(parameter)
          next unless parameter.is_a?(Hash) && parameter["name"].is_a?(String) && parameter["name"].present?

          merged[[ parameter["name"], parameter["in"] ]] = parameter
        end
      end
      merged.values
    end

    def parameter_schema(parameter, label, string_default: false)
      schema = parameter["schema"].is_a?(Hash) ? clean(resolve(parameter["schema"]), label) : {}
      schema = { "type" => "string" }.merge(schema) if schema.empty? || (string_default && !schema.key?("type"))
      description = ImportResult.text(parameter["description"])
      schema = schema.merge("description" => description) if description && !schema.key?("description")
      schema
    end

    def request_body(body, label)
      body = deref(body)
      return [ nil, false ] unless body.is_a?(Hash) && body["content"].is_a?(Hash)

      content = body["content"]
      media, media_object = content.find { |type, _| type.to_s.split(";").first.to_s.strip.match?(JSON_MEDIA) }
      if media.nil?
        types = content.keys.first(3).map { |type| label_text(type, 60) }.join(", ")
        note("#{label} drops its #{types} request body; only JSON bodies can be imported.") if content.any?
        return [ nil, false ]
      end

      schema = media_object.is_a?(Hash) && media_object["schema"].is_a?(Hash) ? clean(resolve(media_object["schema"]), label) : {}
      unless object_type?(schema["type"])
        note("#{label} drops its request body; only a JSON object body can be imported.")
        return [ nil, false ]
      end

      [ schema.merge("type" => "object"), body["required"] == true ]
    end

    def object_type?(type)
      type.nil? || type == "object" || (type.is_a?(Array) && type.include?("object"))
    end

    def deref(node, hops = 0)
      return node unless ref?(node)
      raise ImportError, EXPANDS if hops > REF_DEPTH

      deref(pointer(node["$ref"]), hops + 1)
    end

    def resolve(node, chain = [], depth = 0)
      spend!
      throw :too_deep if depth > MAX_NESTING

      case node
      when Hash then ref?(node) ? resolve_ref(node, chain, depth) : resolve_hash(node, chain, depth)
      when Array then node.map { |value| resolve(value, chain, depth + 1) }
      else node
      end
    end

    def ref?(node) = node.is_a?(Hash) && node["$ref"].is_a?(String)

    def resolve_hash(node, chain, depth)
      node.each_with_object({}) { |(key, value), out| out[key.to_s] = resolve(value, chain, depth + 1) }
    end

    def resolve_ref(node, chain, depth)
      ref = node["$ref"]
      target = pointer(ref)
      if chain.include?(ref) || chain.size >= REF_DEPTH
        note("#{label_text(ref)} refers back to itself or nests references too deeply; that part accepts any value.") if @cycles.add?(ref)
        return {}
      end

      resolved = resolve(target, chain + [ ref ], depth)
      siblings = node.except("$ref")
      return resolved unless resolved.is_a?(Hash) && siblings.any?

      resolved.merge(resolve_hash(siblings, chain, depth))
    end

    def pointer(ref)
      unless ref.is_a?(String) && ref.start_with?("#")
        raise ImportError, "This document refers to #{label_text(ref.to_s)}; only references inside the document (#/…) " \
                           "can be imported."
      end

      ref.delete_prefix("#").split("/").drop(1).reduce(@document) do |node, token|
        key = URI.decode_uri_component(token).gsub("~1", "/").gsub("~0", "~")
        case node
        when Hash then node.fetch(key) { node.fetch(key.to_i, nil) if key.match?(/\A\d+\z/) }
        when Array then key.match?(/\A\d+\z/) ? node[key.to_i] : nil
        end.tap { |found| raise ImportError, "This document refers to #{label_text(ref)}, which it does not contain." if found.nil? }
      end
    end

    def spend!
      @budget -= 1
      raise ImportError, EXPANDS if @budget.negative?
    end

    def clean(schema, label)
      case schema
      when Hash
        schema.each_with_object({}) do |(key, value), out|
          next if DROPPED_KEYS.include?(key)

          if non_finite?(value)
            note("#{label} drops the #{label_text(key, 60)} keyword: it is not a finite number.")
          elsif TEXT_KEYS.include?(key)
            text = ImportResult.text(value)
            out[key] = text if text
          elsif NAME_KEYED.include?(key) && value.is_a?(Hash)
            out[key] = value.transform_values { |child| clean(child, label) }
          else
            out[key] = clean(value, label)
          end
        end.then { |cleaned| exclusive_bounds(cleaned) }
      when Array then schema.map { |value| clean(value, label) }
      else schema
      end
    end

    def non_finite?(value)
      case value
      when Float then !value.finite?
      when Array then value.any? { |child| non_finite?(child) }
      else false
      end
    end

    def exclusive_bounds(schema)
      { "exclusiveMinimum" => "minimum", "exclusiveMaximum" => "maximum" }.each do |exclusive, bound|
        next unless [ true, false ].include?(schema[exclusive])

        if schema[exclusive] && schema[bound].is_a?(Numeric)
          schema[exclusive] = schema.delete(bound)
        else
          schema.delete(exclusive)
        end
      end
      schema
    end

    def label_text(value, max = LABEL_MAX)
      value.to_s.scrub.gsub(/[[:cntrl:]]/, " ")[0, max]
    end

    def note(message)
      @warnings << message
    end
  end
end

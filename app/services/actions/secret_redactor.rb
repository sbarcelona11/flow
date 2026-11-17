# frozen_string_literal: true

module Actions
  class SecretRedactor
    REDACTED = "[redacted]"
    LITERAL_SECRET_MIN_LENGTH = 8
    AUTH_SCHEME = /\A(?:bearer|basic|token|digest)\s+(\S.*)\z/i

    def initialize(secrets = [])
      @secrets = []
      Array(secrets).each { |secret| add(secret) }
    end

    def add(value)
      return self if value.blank?

      @secrets |= [ value.to_s, value.to_s.to_json[1..-2] ]
      @secrets.sort_by! { |secret| -secret.length }
      self
    end

    def add_literal(value)
      credential = value.to_s[AUTH_SCHEME, 1]
      [ value, credential ].compact.each do |literal|
        add(literal) if literal.to_s.strip.length >= LITERAL_SECRET_MIN_LENGTH
      end
      self
    end

    def redact(value)
      case value
      when Hash then value.to_h { |k, v| [ k.is_a?(String) ? redact_text(k) : k, redact(v) ] }
      when Array then value.map { |v| redact(v) }
      when String then redact_text(value)
      else value
      end
    end

    alias call redact

    def redact_text(text)
      return text if text.nil? || @secrets.empty?

      @secrets.reduce(text.to_s) { |scrubbed, secret| scrubbed.gsub(secret, REDACTED) }
    end
  end
end

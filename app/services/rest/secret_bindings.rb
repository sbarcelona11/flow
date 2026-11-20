# frozen_string_literal: true

module Rest
  # "STRIPE_KEY → api.example.com": which Config Item a connector sends to which host. Names and hosts only, never a value.
  # The same line is what a reviewer is shown and what a setup request must repeat back.
  module SecretBindings
    CONFIG_ITEM_KEYS = %w[config_item_name username_item password_item].freeze

    def self.for(auth_config:, base_url:)
      host = URI.parse(base_url.to_s).host.to_s.downcase.chomp(".")
      return [] unless auth_config.is_a?(Hash) && host.present?

      auth_config.slice(*CONFIG_ITEM_KEYS).values.grep(String).uniq.map { |name| "#{name} → #{host}" }
    rescue URI::InvalidURIError
      []
    end
  end
end

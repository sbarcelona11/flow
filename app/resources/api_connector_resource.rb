# frozen_string_literal: true

class ApiConnectorResource < ApplicationResource
  preserve_keys :auth_config, :default_headers

  attributes :id, :name, :base_url, :description, :enabled, :archived_at

  typelize %w[none bearer api_key_header api_key_query basic]
  attribute :auth_type do |connector|
    connector.auth_type
  end

  typelize "Record<string, string>"
  attribute :auth_config do |connector|
    DeepKeyCamelizer.verbatim(connector.auth_config)
  end

  typelize "Record<string, string>"
  attribute :default_headers do |connector|
    DeepKeyCamelizer.verbatim(connector.default_headers)
  end

  typelize :number
  attribute :operations_count do |connector|
    (params[:operation_counts] || {}).fetch(connector.id) { connector.api_operations.size }
  end
end

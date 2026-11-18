# frozen_string_literal: true

class ApiOperationResource < ApplicationResource
  preserve_keys :input_schema

  attributes :id, :name, :path, :summary, :description, :effect, :enabled

  typelize cost_cents: "number | null"
  attributes :cost_cents

  typelize http_method: "'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'"
  attributes :http_method

  typelize "Record<string, unknown>"
  attribute :input_schema do |operation|
    DeepKeyCamelizer.verbatim(operation.input_schema)
  end

  typelize %w[web builder mcp]
  attribute :origin do |operation|
    operation.origin
  end

  typelize %w[reviewed waiting]
  attribute :review_state do |operation|
    operation.review_state
  end

  typelize %w[read write]
  attribute :minimum_effect do |operation|
    operation.minimum_effect
  end
end

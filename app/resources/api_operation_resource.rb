# frozen_string_literal: true

class ApiOperationResource < ApplicationResource
  preserve_keys :input_schema

  attributes :id, :name, :path, :summary, :description, :effect, :enabled

  typelize http_method: "'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'"
  attributes :http_method

  typelize "Record<string, unknown>"
  attribute :input_schema do |operation|
    DeepKeyCamelizer.verbatim(operation.input_schema)
  end

  typelize %w[read write]
  attribute :minimum_effect do |operation|
    operation.minimum_effect
  end
end

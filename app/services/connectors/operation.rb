# frozen_string_literal: true

module Connectors
  Operation = Data.define(:key, :name, :description, :input_schema, :output_schema, :base_effect, :drifted)
end

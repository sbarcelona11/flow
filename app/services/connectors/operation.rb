# frozen_string_literal: true

module Connectors
  # cost_cents is what one call is estimated to cost; nil means the transport declares none.
  Operation = Data.define(:key, :name, :description, :input_schema, :output_schema, :base_effect, :drifted, :cost_cents) do
    def initialize(cost_cents: nil, **attributes) = super
  end
end

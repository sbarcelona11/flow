# frozen_string_literal: true

module Connectors
  Result = Struct.new(:ok, :structured, :text, :error, :unknown, :status, :config_item_names, :redactor,
                      keyword_init: true) do
    def initialize(ok: false, unknown: false, config_item_names: [], **rest)
      super
    end
  end
end

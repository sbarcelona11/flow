# frozen_string_literal: true

class AddKindToSteps < ActiveRecord::Migration[8.1]
  def change
    add_column :steps, :kind, :string, null: false, default: "agent"
    add_column :steps, :kind_config, :jsonb, null: false, default: {}
  end
end

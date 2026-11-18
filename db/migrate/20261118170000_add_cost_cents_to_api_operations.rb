# frozen_string_literal: true

class AddCostCentsToApiOperations < ActiveRecord::Migration[8.1]
  def change
    add_column :api_operations, :cost_cents, :integer
  end
end

# frozen_string_literal: true

class AddCompositeToSteps < ActiveRecord::Migration[8.1]
  def change
    add_column :steps, :composite, :jsonb
  end
end

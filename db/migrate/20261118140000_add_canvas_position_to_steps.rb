# frozen_string_literal: true

class AddCanvasPositionToSteps < ActiveRecord::Migration[8.1]
  def change
    add_column :steps, :canvas_position, :jsonb
  end
end

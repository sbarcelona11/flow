# frozen_string_literal: true

class AddWaitUntilToStepRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :step_runs, :wait_until, :datetime
  end
end

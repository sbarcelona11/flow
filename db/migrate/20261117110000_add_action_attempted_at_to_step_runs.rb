# frozen_string_literal: true

class AddActionAttemptedAtToStepRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :step_runs, :action_attempted_at, :datetime
  end
end

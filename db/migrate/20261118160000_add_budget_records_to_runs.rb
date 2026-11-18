# frozen_string_literal: true

class AddBudgetRecordsToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :step_runs, :budget_cents, :integer
    add_column :workflow_runs, :budget_cents, :integer
    add_column :action_calls, :estimated_cost_cents, :integer
  end
end

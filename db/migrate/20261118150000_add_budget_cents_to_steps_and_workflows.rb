# frozen_string_literal: true

class AddBudgetCentsToStepsAndWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_column :steps, :budget_cents, :integer
    add_column :workflows, :budget_cents, :integer
  end
end

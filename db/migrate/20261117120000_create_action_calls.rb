# frozen_string_literal: true

class CreateActionCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :action_calls do |t|
      t.references :step_run, null: false, foreign_key: { on_delete: :cascade }
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :target_type, null: false
      t.references :mcp_server, foreign_key: { on_delete: :nullify }
      t.string :tool_name
      t.references :tool, foreign_key: { on_delete: :nullify }
      t.string :effect, null: false
      t.string :arguments_digest
      t.string :config_item_names, array: true, null: false, default: []
      t.datetime :attempted_at, null: false
      t.datetime :finished_at
      t.string :outcome
      t.text :error
      t.integer :duration_ms
      t.timestamps
    end

    add_foreign_key :action_calls, :projects, column: %i[project_id company_id], primary_key: %i[id company_id],
                                              on_delete: :cascade, name: "fk_action_calls_project_company"
  end
end

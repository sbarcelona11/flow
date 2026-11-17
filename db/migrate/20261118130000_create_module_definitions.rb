# frozen_string_literal: true

class CreateModuleDefinitions < ActiveRecord::Migration[8.1]
  def change
    create_table :module_definitions do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :scope_type, null: false
      t.bigint :scope_id, null: false
      t.string :kind, null: false
      t.string :namespace, null: false
      t.string :slug, null: false
      t.integer :version, null: false
      t.jsonb :manifest, null: false, default: {}
      t.string :digest, null: false
      t.boolean :enabled, null: false, default: true
      t.datetime :archived_at
      t.timestamps
    end

    add_foreign_key :module_definitions, :projects, column: %i[project_id company_id], primary_key: %i[id company_id],
                                                    on_delete: :cascade, name: "fk_module_definitions_project_company"
    add_index :module_definitions, %i[project_id kind namespace slug version], unique: true,
                                                                              where: "archived_at IS NULL",
                                                                              name: "index_module_definitions_on_project_and_reference"
    add_check_constraint :module_definitions, "scope_type = 'Project' AND scope_id = project_id",
                         name: "module_definitions_project_scope"
    add_check_constraint :module_definitions, "kind IN ('type', 'capability', 'block')",
                         name: "module_definitions_kind"
  end
end

# frozen_string_literal: true

class CreateApiConnectors < ActiveRecord::Migration[8.1]
  def change
    create_table :api_connectors do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :scope_type, null: false
      t.bigint :scope_id, null: false
      t.string :name, null: false
      t.string :base_url, null: false
      t.string :auth_type, null: false, default: "none"
      t.jsonb :auth_config, null: false, default: {}
      t.jsonb :default_headers, null: false, default: {}
      t.text :description
      t.boolean :enabled, null: false, default: true
      t.datetime :archived_at
      t.timestamps
    end

    add_foreign_key :api_connectors, :projects, column: %i[project_id company_id], primary_key: %i[id company_id],
                                                on_delete: :cascade, name: "fk_api_connectors_project_company"
    add_index :api_connectors, %i[project_id name], unique: true, where: "archived_at IS NULL",
                                                    name: "index_api_connectors_on_project_and_name"
    add_check_constraint :api_connectors, "scope_type = 'Project' AND scope_id = project_id",
                         name: "api_connectors_project_scope"

    create_table :api_operations do |t|
      t.references :api_connector, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :method, null: false
      t.string :path, null: false
      t.string :summary
      t.text :description
      t.jsonb :input_schema, null: false, default: {}
      t.string :effect, null: false
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_index :api_operations, %i[api_connector_id name], unique: true
  end
end

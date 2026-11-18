# frozen_string_literal: true


class AddAuthoringReviewToConnectorsAndModules < ActiveRecord::Migration[8.1]
  TABLES = %i[api_connectors api_operations module_definitions].freeze

  def up
    TABLES.each do |table|
      add_column table, :origin, :string, null: false, default: "web"
      add_column table, :created_by_id, :bigint
      add_column table, :origin_session_id, :bigint
      add_column table, :reviewed_by_id, :bigint
      add_column table, :reviewed_at, :datetime
      add_foreign_key table, :users, column: :created_by_id, on_delete: :nullify
      add_check_constraint table, "origin IN ('web', 'builder', 'mcp')", name: "#{table}_origin"
    end

    TABLES.each { |table| execute "UPDATE #{table} SET reviewed_at = created_at" }

    TABLES.each do |table|
      add_check_constraint table, "NOT enabled OR reviewed_at IS NOT NULL", name: "#{table}_enabled_requires_review"
    end
  end

  def down
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_enabled_requires_review"
      remove_check_constraint table, name: "#{table}_origin"
      remove_foreign_key table, column: :created_by_id
      remove_column table, :reviewed_at
      remove_column table, :reviewed_by_id
      remove_column table, :origin_session_id
      remove_column table, :created_by_id
      remove_column table, :origin
    end
  end
end

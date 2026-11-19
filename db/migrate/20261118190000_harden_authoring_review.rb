# frozen_string_literal: true

class HardenAuthoringReview < ActiveRecord::Migration[8.1]
  TABLES = %i[api_connectors api_operations module_definitions].freeze

  def up
    TABLES.each do |table|
      change_column_default table, :origin, from: "web", to: nil
      add_column table, :rejected_at, :datetime
      add_column table, :rejected_by_id, :bigint
      add_index table, :created_by_id
      add_check_constraint table, "rejected_at IS NULL OR (NOT enabled AND reviewed_at IS NULL)",
                           name: "#{table}_rejected_never_enabled"
    end
  end

  def down
    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_rejected_never_enabled"
      remove_index table, :created_by_id
      remove_column table, :rejected_by_id
      remove_column table, :rejected_at
      change_column_default table, :origin, from: nil, to: "web"
    end
  end
end

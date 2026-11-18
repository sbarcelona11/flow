# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261118180000_add_authoring_review_to_connectors_and_modules")

class AuthoringReviewMigrationTest < ActiveSupport::TestCase
  test "existing rows are backfilled as reviewed at their creation time, enabled or not, with no reviewer" do
    project = create(:project, :standalone)
    created = Time.utc(2026, 1, 2, 3, 4, 5)
    enabled = create(:api_connector, scope: project)
    disabled = create(:api_connector, scope: project, enabled: false)
    operation = create(:api_operation, api_connector: enabled)
    block = create(:module_definition, scope: project)
    records = [ enabled, disabled, operation, block ]
    records.each { |record| record.update_columns(created_at: created) }
    migration = AddAuthoringReviewToConnectorsAndModules.new

    ActiveRecord::Migration.suppress_messages do
      migration.migrate(:down)
      migration.migrate(:up)
    end

    rows = records.map { |record| ApiConnector.connection.select_one("SELECT reviewed_at, reviewed_by_id, origin, enabled FROM #{record.class.table_name} WHERE id = #{record.id}") }
    rows.each do |row|
      assert_equal created, row["reviewed_at"].utc
      assert_nil row["reviewed_by_id"]
      assert_equal "web", row["origin"]
    end
    assert_equal [ true, false, true, true ], rows.map { |row| row["enabled"] }
  ensure
    [ ApiConnector, ApiOperation, ModuleDefinition ].each(&:reset_column_information)
  end
end

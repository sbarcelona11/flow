# frozen_string_literal: true

require "test_helper"

class AuthoringHardeningMigrationTest < ActiveSupport::TestCase
  %w[api_connectors api_operations module_definitions].each do |table|
    test "#{table}.origin has no default, so an unstamped insert fails closed" do
      column = ActiveRecord::Base.connection.columns(table).find { |candidate| candidate.name == "origin" }

      assert_nil column.default
      assert_not column.null
    end

    test "#{table} is indexed on created_by_id" do
      assert ActiveRecord::Base.connection.index_exists?(table, :created_by_id)
    end
  end

  test "raw SQL cannot insert an enabled row that nobody reviewed" do
    project = create(:project, :standalone)

    assert_raises(ActiveRecord::NotNullViolation, ActiveRecord::CheckViolation) do
      ActiveRecord::Base.connection.execute(
        "INSERT INTO api_connectors (name, base_url, scope_type, scope_id, project_id, company_id, created_at, updated_at) " \
        "VALUES ('raw', 'https://api.example.com', 'Project', #{project.id}, #{project.id}, #{project.company_id}, now(), now())"
      )
    end
  end
end

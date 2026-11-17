# frozen_string_literal: true

require "test_helper"

class ConfigItems::ReferenceResolverTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
  end

  test "replaces a project secret" do
    item = create(:config_item, scope: @project, name: "API_KEY", item_type: :secret, value: "s3cr3t")

    text, items = ConfigItems::ReferenceResolver.new(project: @project).resolve("Bearer config_item:API_KEY")

    assert_equal "Bearer s3cr3t", text
    assert_equal [ item ], items
  end

  # Config items are project-scoped only since 02685e33, so the brief's company
  # fallback has no rows to fall back to; what remains is that another tenant's
  # item of the same name is never used.
  test "never resolves another project's item" do
    create(:config_item, scope: create(:project, :standalone), name: "API_KEY", value: "foreign")

    assert_raises(ConfigItems::ReferenceResolver::Missing) do
      ConfigItems::ReferenceResolver.new(project: @project).resolve("config_item:API_KEY")
    end
  end

  test "raises naming a missing item" do
    create(:config_item, scope: @project, name: "PRESENT", value: "v")

    error = assert_raises(ConfigItems::ReferenceResolver::Missing) do
      ConfigItems::ReferenceResolver.new(project: @project).resolve("config_item:PRESENT and config_item:ABSENT")
    end
    assert_equal "ABSENT", error.name
    assert_match(/ABSENT/, error.message)
  end

  test "returns text without references unchanged and resolves each item once" do
    item = create(:config_item, scope: @project, name: "TOKEN", value: "t")
    resolver = ConfigItems::ReferenceResolver.new(project: @project)

    assert_equal [ "plain", [] ], resolver.resolve("plain")
    assert_equal [ "t:t", [ item ] ], resolver.resolve("config_item:TOKEN:config_item:TOKEN")
  end
end

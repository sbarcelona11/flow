# frozen_string_literal: true

require "test_helper"

class ModuleDefinitionTest < ActiveSupport::TestCase
  setup do
    @project = create(:project, :standalone)
  end

  test "a valid definition saves with tenant columns and a digest" do
    definition = build(:module_definition, scope: @project)

    assert definition.save, definition.errors.full_messages.to_sentence
    assert_equal @project.id, definition.project_id
    assert_equal @project.company_id, definition.company_id
    assert_equal Modules::Manifest.from_hash(definition.manifest).digest, definition.digest
  end

  test "the digest follows the manifest" do
    definition = create(:module_definition, scope: @project, origin: "builder")
    before = definition.digest

    definition.update!(manifest: definition.manifest.merge("label" => "Renamed"))

    assert_not_equal before, definition.digest
  end

  test "fills the row's identity from the manifest and refuses a mismatch" do
    manifest = { "kind" => "type", "namespace" => "acme", "slug" => "sku", "version" => 3, "label" => "SKU", "schema" => { "type" => "string" } }

    definition = ModuleDefinition.create!(scope: @project, manifest: manifest)
    assert_equal [ "type", "acme", "sku", 3 ], definition.values_at(:kind, :namespace, :slug, :version)

    mismatched = build(:module_definition, scope: @project, slug: "other", manifest: manifest)
    assert_not mismatched.valid?
    assert_includes mismatched.errors[:slug], "must match the manifest (sku)"
  end

  test "refuses an invalid manifest with the reason" do
    definition = build(:module_definition, scope: @project, manifest: { "kind" => "type", "namespace" => "acme", "slug" => "x",
                                                                         "version" => 1, "label" => "X", "schema" => {}, "run" => "ls" })

    assert_not definition.valid?
    assert_match(/run/, definition.errors[:manifest].first)
  end

  test "refuses the aixle namespace for project modules" do
    definition = build(:module_definition, scope: @project, namespace: "aixle", slug: "string")

    assert_not definition.valid?
    assert_includes definition.errors[:namespace], "is reserved for built-in modules"
  end

  test "refuses a malformed namespace or slug" do
    definition = build(:module_definition, scope: @project, namespace: "Acme Corp", slug: "a_b")

    assert_not definition.valid?
    assert definition.errors[:namespace].any?
    assert definition.errors[:slug].any?
  end

  test "is unique per project, kind, namespace, slug and version among live rows" do
    create(:module_definition, scope: @project, slug: "sku")

    duplicate = build(:module_definition, scope: @project, slug: "sku")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], "is already defined at this version in this project"

    assert build(:module_definition, scope: @project, slug: "sku", version: 2).valid?
    assert build(:module_definition, scope: @project, slug: "sku", kind: "capability").tap { |d| d.manifest = build(:module_definition, :capability, slug: "sku").manifest }.valid?
    assert build(:module_definition, scope: create(:project, :standalone), slug: "sku").valid?
  end

  test "refuses a version beyond 32 bits without raising" do
    [ 2_147_483_648, 99_999_999_999_999_999_999 ].each do |version|
      definition = build(:module_definition, scope: @project, slug: "big")
      definition.version = version
      definition.manifest = definition.manifest.merge("version" => version)

      assert_not definition.valid?
      assert_nothing_raised { definition.save }
    end
  end

  test "capability slugs may contain dots, other kinds may not" do
    capability = build(:module_definition, :capability, scope: @project, slug: "image.generate")
    assert capability.save, capability.errors.full_messages.to_sentence

    assert_not build(:module_definition, scope: @project, slug: "image.generate").valid?
  end

  test "a NUL anywhere in the manifest is refused and never raises on save" do
    definition = build(:module_definition, scope: @project, slug: "nul",
                                            manifest: { "kind" => "type", "namespace" => "acme", "slug" => "nul", "version" => 1,
                                                        "label" => "N", "schema" => { "title" => "a\u0000b", "properties" => { "k\u0000" => {} } } })

    assert_not definition.valid?
    assert_nothing_raised { definition.save }
    assert_not definition.persisted?
  end

  test "an archived definition frees its reference" do
    create(:module_definition, scope: @project, slug: "sku").archive!

    assert build(:module_definition, scope: @project, slug: "sku").valid?
  end

  test "the database refuses a duplicate that skips validation" do
    create(:module_definition, scope: @project, slug: "sku")

    assert_raises(ActiveRecord::RecordNotUnique) do
      build(:module_definition, scope: @project, slug: "sku").save!(validate: false)
    end
  end

  test "is project scoped only" do
    company = create(:company)
    definition = build(:module_definition, scope: company)

    assert_not definition.valid?
    assert_includes definition.errors[:scope_type], "must be a project"
  end

  test "for_project returns only live rows of the project" do
    mine = create(:module_definition, scope: @project, slug: "mine")
    create(:module_definition, scope: @project, slug: "old").archive!
    create(:module_definition, scope: create(:project, :standalone), slug: "theirs")

    assert_equal [ mine ], ModuleDefinition.for_project(@project).to_a
  end

  test "the database refuses an enabled row that was never reviewed" do
    record = create(:module_definition, scope: @project)

    assert_raises(ActiveRecord::StatementInvalid) { record.update_columns(reviewed_at: nil, enabled: true) }
  end

  test "the database refuses an origin it does not know" do
    record = create(:module_definition, scope: @project)

    assert_raises(ActiveRecord::StatementInvalid) { record.update_columns(origin: "robot") }
  end

  test "a builder-origin row saves disabled whatever enabled it was given" do
    record = build(:module_definition, scope: @project)
    record.assign_attributes(origin: "builder", enabled: true)

    assert record.save, record.errors.full_messages.to_sentence
    assert_equal false, record.reload.enabled # rubocop:disable Minitest/RefuteFalse
    assert_nil record.reviewed_at
    assert_equal "waiting", record.review_state
    assert_includes ModuleDefinition.awaiting_review, record
  end

  test "an mcp-origin row cannot be enabled by an update until it is reviewed" do
    record = build(:module_definition, scope: @project)
    record.assign_attributes(origin: "mcp")
    record.save!

    record.update!(enabled: true)

    assert_equal false, record.reload.enabled # rubocop:disable Minitest/RefuteFalse
  end

  test "a row created on the web path is reviewed" do
    record = create(:module_definition, scope: @project)

    assert_equal "web", record.origin
    assert_equal "reviewed", record.review_state
    assert_not_nil record.reviewed_at
    assert_not_includes ModuleDefinition.awaiting_review, record
  end

  test "an unknown origin is refused" do
    record = build(:module_definition, scope: @project)
    record.origin = "robot"

    assert_not record.valid?
    assert record.errors[:origin].any?
  end

  test "enabling an unreviewed web row is a readable validation error" do
    record = create(:module_definition, scope: @project)
    record.reviewed_at = nil
    record.enabled = true

    assert_not record.valid?
    assert_includes record.errors[:enabled], "needs a review before it can be enabled"
  end

  test "a reviewed manifest cannot change and neither can its identity" do
    definition = create(:module_definition, scope: @project)

    definition.manifest = definition.manifest.merge("label" => "Renamed")
    assert_not definition.valid?
    assert_includes definition.errors[:base], "A reviewed module can't change; save a new version"

    definition.reload
    definition.assign_attributes(version: 2, manifest: definition.manifest.merge("version" => 2))
    assert_not definition.valid?
    assert_not definition.save
    assert_equal 1, definition.reload.version
  end

  test "enable, disable and archive stay allowed on a reviewed module" do
    definition = create(:module_definition, scope: @project)

    definition.update!(enabled: false)
    definition.update!(enabled: true)
    definition.archive!

    assert definition.reload.archived?
  end

  test "an unreviewed module's manifest can still change" do
    definition = build(:module_definition, scope: @project, origin: "builder")
    definition.save!

    definition.update!(manifest: definition.manifest.merge("label" => "Renamed"))

    assert_equal "Renamed", definition.reload.manifest["label"]
  end

  test "clearing the review stamp does not unlock a reviewed manifest" do
    definition = create(:module_definition, scope: @project)

    definition.assign_attributes(reviewed_at: nil, manifest: definition.manifest.merge("label" => "Renamed"))

    assert_not definition.valid?
  end
end

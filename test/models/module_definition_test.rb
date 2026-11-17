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
    definition = create(:module_definition, scope: @project)
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
end

# frozen_string_literal: true

class ModuleDefinition < ApplicationRecord
  KINDS = %w[type capability block].freeze
  NAME_FORMAT = Modules::Manifest::NAME
  CAPABILITY_SLUG_FORMAT = Modules::Manifest::CAPABILITY_SLUG

  belongs_to :scope, polymorphic: true
  include TenantColumns
  include Archivable
  include Authored

  before_validation :adopt_manifest
  before_save :adopt_manifest

  validates :kind, inclusion: { in: KINDS }
  validates :namespace, format: { with: NAME_FORMAT }, length: { maximum: 64 }
  validates :slug, format: { with: NAME_FORMAT }, length: { maximum: 64 }, unless: :capability?
  validates :slug, format: { with: CAPABILITY_SLUG_FORMAT }, length: { maximum: 64 }, if: :capability?
  validates :namespace, exclusion: { in: [ Modules::Registry::BUILTIN_NAMESPACE ], message: "is reserved for built-in modules" }
  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 1,
                                      less_than_or_equal_to: Modules::Manifest::MAX_VERSION }
  validates :scope_type, inclusion: { in: %w[Project], message: "must be a project" }
  validates :slug, uniqueness: { scope: %i[project_id kind namespace version], conditions: -> { where(archived_at: nil) },
                                 if: :version_in_range?, message: "is already defined at this version in this project" }
  validate :manifest_is_valid
  validate :reviewed_module_is_unchanged, on: :update

  scope :for_project, ->(project) { unarchived.where(scope_type: "Project", scope_id: project.id) }
  scope :enabled, -> { where(enabled: true) }

  def parsed_manifest
    return @parsed_manifest if defined?(@parsed_manifest) && @parsed_manifest_source == manifest

    @parsed_manifest_source = manifest.deep_dup
    @parsed_manifest = Modules::Manifest.from_hash(manifest)
  end

  private

  def capability? = kind == "capability"

  def version_in_range?
    version.is_a?(Integer) && version.between?(1, Modules::Manifest::MAX_VERSION)
  end

  def adopt_manifest
    parsed = parsed_manifest
    self.digest = parsed.digest
    self.kind = parsed.kind if kind.blank?
    self.namespace = parsed.namespace if namespace.blank?
    self.slug = parsed.slug if slug.blank?
    self.version = parsed.version if version.blank?
  rescue Modules::Manifest::Invalid
    self.digest = ""
  end

  def reviewed_module_is_unchanged
    return if reviewed_at_in_database.nil?
    return unless will_save_change_to_manifest? || will_save_change_to_kind? || will_save_change_to_namespace? ||
                  will_save_change_to_slug? || will_save_change_to_version?

    errors.add(:base, "A reviewed module can't change; save a new version")
  end

  # Re-checked on every save, so enabling a composite again re-checks the ids its steps name.
  def check_composite_references(parsed)
    return unless parsed.kind == "block" && parsed.executor == "composite" && scope_type == "Project" && scope.present?

    problem = Modules::Composite::References.new(scope, parsed.graph["steps"]).problem
    errors.add(:manifest, problem) if problem
  end

  def manifest_is_valid
    parsed = parsed_manifest
    { kind: parsed.kind, namespace: parsed.namespace, slug: parsed.slug, version: parsed.version }.each do |attribute, value|
      errors.add(attribute, "must match the manifest (#{value})") unless public_send(attribute) == value
    end
    check_composite_references(parsed)
    return unless parsed.kind == "type" && errors.empty? && scope_type == "Project" && scope.present?

    problem = Modules::Registry.new(scope, overlay: parsed).type_problem(parsed.key)
    errors.add(:manifest, problem) if problem
  rescue Modules::Manifest::Invalid => e
    errors.add(:manifest, e.message)
  end
end

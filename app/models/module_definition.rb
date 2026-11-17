# frozen_string_literal: true

class ModuleDefinition < ApplicationRecord
  KINDS = %w[type capability block].freeze
  NAME_FORMAT = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  belongs_to :scope, polymorphic: true
  include TenantColumns
  include Archivable

  before_validation :adopt_manifest
  before_save :adopt_manifest

  validates :kind, inclusion: { in: KINDS }
  validates :namespace, :slug, format: { with: NAME_FORMAT }, length: { maximum: 64 }
  validates :namespace, exclusion: { in: [ Modules::Registry::BUILTIN_NAMESPACE ], message: "is reserved for built-in modules" }
  validates :version, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :scope_type, inclusion: { in: %w[Project], message: "must be a project" }
  validates :slug, uniqueness: { scope: %i[project_id kind namespace version], conditions: -> { where(archived_at: nil) },
                                 message: "is already defined at this version in this project" }
  validate :manifest_is_valid

  scope :for_project, ->(project) { unarchived.where(scope_type: "Project", scope_id: project.id) }
  scope :enabled, -> { where(enabled: true) }

  def parsed_manifest
    return @parsed_manifest if defined?(@parsed_manifest) && @parsed_manifest_source == manifest

    @parsed_manifest_source = manifest.deep_dup
    @parsed_manifest = Modules::Manifest.from_hash(manifest)
  end

  private

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

  def manifest_is_valid
    parsed = parsed_manifest
    { kind: parsed.kind, namespace: parsed.namespace, slug: parsed.slug, version: parsed.version }.each do |attribute, value|
      errors.add(attribute, "must match the manifest (#{value})") unless public_send(attribute) == value
    end
    return unless parsed.kind == "type" && errors.empty? && scope_type == "Project" && scope.present?

    problem = Modules::Registry.new(scope, overlay: parsed).type_problem(parsed.key)
    errors.add(:manifest, problem) if problem
  rescue Modules::Manifest::Invalid => e
    errors.add(:manifest, e.message)
  end
end

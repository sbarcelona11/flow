# frozen_string_literal: true

class ModuleDefinitionResource < ApplicationResource
  preserve_keys :manifest

  typelize id: :number, key: :string, kind: "'type' | 'capability' | 'block'", namespace: :string, slug: :string, version: :number,
           label: :string, description: "string | null", enabled: :boolean, archived_at: "string | null",
           origin: "'web' | 'builder' | 'mcp'", review_state: "'reviewed' | 'waiting' | 'rejected'",
           reviewed_at: "string | null", review_digest: :string,
           created_by: "{ id: number; name: string | null } | null",
           status: "'valid' | 'invalid' | 'unresolved' | null", reason: "string | null",
           manifest: "Record<string, unknown> | null"
  attributes :id, :kind, :namespace, :slug, :version, :enabled, :archived_at, :origin, :reviewed_at

  attribute(:key) { |definition| "#{definition.namespace}/#{definition.slug}@#{definition.version}" }
  attribute(:label) { |definition| definition.manifest["label"] }
  attribute(:description) { |definition| definition.manifest["description"] }
  attribute(:review_state, &:review_state)
  attribute(:review_digest) { |definition| Authoring::Review.digest_for(definition) }
  attribute(:created_by) { |definition| definition.created_by && { id: definition.created_by.id, name: definition.created_by.name } }
  attribute(:status) { |_definition| (params[:assessment] || []).first }
  attribute(:reason) { |_definition| (params[:assessment] || []).second }
  attribute(:manifest) { |definition| params[:with_manifest] ? definition.manifest : nil }
end

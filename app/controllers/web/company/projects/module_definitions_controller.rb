# frozen_string_literal: true

# Block, type and capability definitions of a project, authored in the web UI. Reviewing (approve, reject) lives here and
# nowhere a token reaches: Authoring::Review needs the live cookie session this tree authenticates.
class Web::Company::Projects::ModuleDefinitionsController < Web::Company::Projects::ApplicationController
  requires_feature :workflow_action_steps
  rate_limit to: 20, within: 1.minute, only: %i[create new_version], by: -> { current_user.id },
             with: -> { render json: { error: "Too many new blocks. Try again in a minute." }, status: :too_many_requests }

  MAX_LISTED = 500

  rescue_from Modules::Manifest::Invalid, ArgumentError do |error|
    render json: { error: error.message }, status: :unprocessable_content
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_content
  end
  rescue_from ActiveRecord::RecordNotUnique do
    render json: { error: "That block already exists at this version." }, status: :unprocessable_content
  end
  rescue_from Authoring::Review::ContentChanged do |error|
    render json: { error: "#{error.message}. Reload and look at it again before approving." }, status: :conflict
  end
  rescue_from Authoring::Review::AlreadyReviewed, Authoring::Review::Rejected, Authoring::Review::Archived,
              Authoring::Review::ConnectorNotReviewed do |error|
    render json: { error: error.message }, status: :unprocessable_content
  end

  def index
    definitions = ModuleDefinition.where(scope_type: "Project", scope_id: current_project.id).includes(:created_by)
                                  .order(:namespace, :slug, :version).limit(MAX_LISTED).to_a
    registry = Modules::Registry.new(current_project)
    render json: definitions.map { |definition| present(definition, registry: registry) }
  end

  def show
    render json: present(find_definition, with_manifest: true)
  end

  def create
    manifest, warnings = manifest_from_params
    definition = ModuleDefinition.new(scope: current_project, manifest: manifest)
    save_web!(definition)
    render json: present(definition, with_manifest: true).merge(warnings: warnings), status: :created
  end

  def new_version
    previous = find_definition
    manifest, warnings = manifest_from_params(previous: previous)
    definition = ModuleDefinition.new(scope: current_project, manifest: manifest)
    save_web!(definition)
    render json: present(definition, with_manifest: true).merge(warnings: warnings), status: :created
  end

  def approve
    definition = find_definition
    digest = params[:expected_digest].to_s
    return render json: { error: "Send the digest of the version you reviewed." }, status: :unprocessable_content if digest.blank?

    Authoring::Review.approve!(definition, user_session: current_user_session, project: current_project,
                                           expected_digests: { definition => digest })
    render json: present(definition.reload)
  end

  def reject
    definition = find_definition
    Authoring::Review.reject!(definition, user_session: current_user_session, project: current_project)
    render json: present(definition.reload)
  end

  def enable
    definition = find_definition
    definition.enabled = true
    definition.save!
    render json: present(definition)
  end

  def disable
    definition = find_definition
    definition.update!(enabled: false)
    render json: present(definition)
  end

  def archive
    definition = find_definition
    definition.update!(archived_at: Time.current, enabled: false)
    render json: present(definition)
  end

  private

  def find_definition
    ModuleDefinition.for_project(current_project).find(params[:id])
  end

  def save_web!(definition)
    Authoring::Review.stamp_web!(definition, current_user)
    definition.save!
  end

  def project_operations
    ApiOperation.joins(:api_connector).where(api_connectors: { scope_type: "Project", scope_id: current_project.id, archived_at: nil })
  end

  def manifest_from_params(previous: nil)
    source = params[:from_operation]
    text = params[:manifest]
    raise ArgumentError, "Send either from_operation or manifest." if source.present? == text.present?

    source.present? ? manifest_from_operation(source, previous) : manifest_from_text(text, previous)
  end

  def manifest_from_operation(source, previous)
    raise ArgumentError, "from_operation must be an object." unless source.respond_to?(:permit)
    raise ArgumentError, "Only a block can be built from an operation." if previous && previous.kind != "block"

    operation = project_operations.find(source[:api_operation_id])
    result = Modules::BlockBuilder.from_operation(
      project: current_project, operation: operation, label: source[:label], description: source[:description].presence,
      settings: source[:settings].presence && Array(source[:settings]).map(&:to_s), effect: source[:effect].presence,
      namespace: previous&.namespace || source[:namespace].presence || Modules::BlockBuilder::DEFAULT_NAMESPACE, slug: previous&.slug
    )
    [ result.manifest, result.warnings ]
  end

  def manifest_from_text(text, previous)
    raise ArgumentError, "The manifest must be text (YAML or JSON)." unless text.is_a?(String)

    parsed = Modules::Manifest.parse(text)
    return [ parsed.to_h.deep_dup, [] ] unless previous

    same = { "kind" => previous.kind, "namespace" => previous.namespace, "slug" => previous.slug }
    different = same.find { |attribute, value| parsed.to_h[attribute] != value }
    raise ArgumentError, "A new version keeps the same #{different.first} (#{different.second})." if different

    latest = ModuleDefinition.where(scope_type: "Project", scope_id: current_project.id, kind: previous.kind,
                                    namespace: previous.namespace, slug: previous.slug).maximum(:version).to_i
    [ Modules::Manifest.from_hash(parsed.to_h.deep_dup.merge("version" => latest + 1)).to_h.deep_dup, [] ]
  end

  def present(definition, registry: nil, with_manifest: false)
    ModuleDefinitionResource.new(definition, params: { assessment: assess(definition, registry), with_manifest: with_manifest }).to_h
  end

  def assess(definition, registry)
    return [ nil, nil ] if definition.archived?

    registry = Modules::Registry.new(current_project, overlay: definition.parsed_manifest) unless registry && definition.enabled?
    entry = registry.public_send(definition.kind, "#{definition.namespace}/#{definition.slug}@#{definition.version}")
    [ entry.status, entry.reason ]
  rescue Modules::Registry::Unknown, Modules::Manifest::Invalid => e
    [ "invalid", e.message ]
  end
end

# frozen_string_literal: true

class Web::Company::Projects::ApiConnectorsController < Web::Company::Projects::ApplicationController
  requires_feature :workflow_action_steps
  rate_limit to: 30, within: 1.minute, only: %i[approve reject], by: -> { current_user.id },
             with: -> { render json: { error: "Too many reviews. Try again in a minute." }, status: :too_many_requests }
  rate_limit to: 60, within: 1.minute, only: :review, by: -> { current_user.id },
             with: -> { render json: { error: "Too many requests. Try again in a minute." }, status: :too_many_requests }

  CONFIG_ITEM_NAMES_LIMIT = 500
  REVIEW_LIST_LIMIT = 200

  class BadRequest < StandardError; end

  rescue_from BadRequest, Authoring::Review::AlreadyReviewed, Authoring::Review::Rejected, Authoring::Review::Archived,
              Authoring::Review::ConnectorNotReviewed do |error|
    render json: { error: error.message }, status: :unprocessable_content
  end
  rescue_from Authoring::Review::ContentChanged do |error|
    render json: { error: "#{error.message}. Reload and look at it again before approving." }, status: :conflict
  end

  def index
    connectors = project_connectors.unarchived.order(:name).to_a
    archived = project_connectors.archived.order(archived_at: :desc).to_a
    counts = ApiOperation.where(api_connector_id: connectors.map(&:id) + archived.map(&:id)).group(:api_connector_id).count
    resource = ->(c) { ApiConnectorResource.new(c, params: { operation_counts: counts }).to_h }

    render inertia: "Projects/ApiConnectors/ApiConnectorsPage", props: {
      project: project_props,
      api_connectors: connectors.map(&resource),
      archived_connectors: archived.map(&resource),
      config_item_names: ConfigItem.visible_for_project(current_project).order(:name).limit(CONFIG_ITEM_NAMES_LIMIT).pluck(:name)
    }
  end

  def new
    render_form(nil)
  end

  def create
    connector = ApiConnector.new(scope: current_project)
    connector.assign_attributes(connector_params)
    Authoring::Review.stamp_web!(connector, current_user, user_session: current_user_session)
    connector.save!
    redirect_to edit_company_project_api_connector_path(current_project, connector), notice: "Connector created"
  rescue ActiveRecord::RecordInvalid
    redirect_to new_company_project_api_connector_path(current_project), inertia: { errors: connector.errors }
  end

  def edit
    render_form(find_connector)
  end

  def update
    connector = find_connector
    connector.update!(connector_params)
    redirect_to edit_company_project_api_connector_path(current_project, connector), notice: "Connector updated"
  rescue ActiveRecord::RecordInvalid
    redirect_to edit_company_project_api_connector_path(current_project, connector), inertia: { errors: connector.errors }
  end

  def archive
    find_connector.archive!
    redirect_to company_project_api_connectors_path(current_project), notice: "Connector archived"
  end

  def unarchive
    connector = project_connectors.archived.find(params[:id])
    connector.unarchive!
    redirect_to company_project_api_connectors_path(current_project), notice: "Connector restored"
  rescue ActiveRecord::RecordInvalid
    redirect_to company_project_api_connectors_path(current_project),
                alert: "A connector named #{connector.name} already exists in this project."
  end

  # What the reviewer is asked to approve, with the digests they must send back. Operations and blocks come with the
  # connector so one screen shows the whole proposal.
  def review
    render json: review_payload(find_connector)
  end

  # `expected_digest` is the connector as the reviewer saw it (needed only while the connector itself is waiting) and
  # `operation_digests` maps each operation they saw to its digest. Anything not listed stays waiting.
  def approve
    connector = find_connector
    digests = operation_digests
    records = []
    expected = {}
    digest = params[:expected_digest].to_s
    raise BadRequest, "Send the digest of the version you reviewed." if digest.blank?

    # Operations are approved against the connector the reviewer saw, so an edit of a reviewed connector in between is a 409.
    expected[connector] = digest
    records << connector unless connector.reviewed?
    digests.each do |id, operation_digest|
      operation = connector.api_operations.find(id)
      records << operation
      expected[operation] = operation_digest
    end
    raise BadRequest, "There is nothing waiting for review here." if records.empty?
    raise Authoring::Review::ContentChanged, "ApiConnector #{connector.id} changed after it was shown for review" if connector.reviewed? && Authoring::Review.digest_for(connector) != digest

    Authoring::Review.approve!(records, user_session: current_user_session, project: current_project, expected_digests: expected)
    render json: review_payload(connector.reload)
  end

  # Rejecting a waiting connector rejects it together with everything waiting under it. On a reviewed connector, only the
  # listed waiting operations are rejected.
  def reject
    connector = find_connector
    records = if connector.reviewed?
      Array(params[:operation_ids]).first(REVIEW_LIST_LIMIT).map { |id| connector.api_operations.find(id) }
    else
      [ connector ] + connector.api_operations.awaiting_review.order(:id).to_a
    end
    raise BadRequest, "There is nothing waiting for review here." if records.empty?

    Authoring::Review.reject!(records, user_session: current_user_session, project: current_project)
    render json: review_payload(project_connectors.find(connector.id))
  end

  private

  def operation_digests
    raw = params[:operation_digests]
    return {} if raw.blank?
    raise BadRequest, "operation_digests must be an object." unless raw.respond_to?(:to_unsafe_h)

    pairs = raw.to_unsafe_h.to_a
    raise BadRequest, "Too many operations in one review." if pairs.size > REVIEW_LIST_LIMIT
    raise BadRequest, "Each operation needs the digest you reviewed." unless pairs.all? { |_id, digest| digest.is_a?(String) && digest.present? }

    pairs
  end

  def review_payload(connector)
    operations = connector.api_operations.order(:name).limit(REVIEW_LIST_LIMIT).to_a
    blocks = ModuleDefinition.where(scope_type: "Project", scope_id: current_project.id, kind: "block", archived_at: nil)
                             .where("manifest #>> '{uses,connection}' = ?", connector.name)
                             .order(:namespace, :slug, :version).limit(REVIEW_LIST_LIMIT).to_a
    {
      connector: ApiConnectorResource.new(connector, params: { operation_counts: { connector.id => operations.size } }).to_h,
      host: connector.host,
      secretBindings: Rest::SecretBindings.for(auth_config: connector.auth_config, base_url: connector.base_url),
      operations: operations.map { |operation| ApiOperationResource.new(operation).to_h },
      blocks: blocks.map { |definition| ModuleDefinitionResource.new(definition, params: { assessment: [ nil, nil ] }).to_h }
    }
  end

  def preserved_param_paths
    [ %i[apiConnector defaultHeaders], %i[api_connector default_headers] ]
  end

  def project_connectors
    ApiConnector.where(scope_type: "Project", scope_id: current_project.id)
  end

  def find_connector
    project_connectors.unarchived.find(params[:id])
  end

  def render_form(connector)
    render inertia: "Projects/ApiConnectors/ApiConnectorPage", props: {
      project: project_props,
      api_connector: connector && ApiConnectorResource.new(connector).to_h,
      operations: connector ? connector.api_operations.order(:name).map { |o| ApiOperationResource.new(o).to_h } : [],
      config_item_names: ConfigItem.visible_for_project(current_project).pluck(:name)
    }
  end

  def connector_params
    params.require(:api_connector).permit(:name, :base_url, :auth_type, :description, :enabled,
                                          auth_config: {}, default_headers: {})
  end
end

# frozen_string_literal: true

class Web::Company::Projects::ApiConnectorsController < Web::Company::Projects::ApplicationController
  requires_feature :workflow_action_steps

  CONFIG_ITEM_NAMES_LIMIT = 500

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
    Authoring::Review.stamp_web!(connector, current_user)
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

  private

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

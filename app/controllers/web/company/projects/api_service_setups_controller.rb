# frozen_string_literal: true

# The Add a REST service wizard's one POST: connector, operations and blocks together. The person who confirms
# the summary screen is the reviewer, so this controller (and only a web controller may) hands the service
# the callable that stamps each record as reviewed by them.
class Web::Company::Projects::ApiServiceSetupsController < Web::Company::Projects::ApplicationController
  requires_feature :workflow_action_steps
  rate_limit to: 20, within: 1.minute, only: :create, by: -> { current_user.id },
             with: -> { render json: { error: "Too many new services. Try again in a minute." }, status: :too_many_requests }

  CONNECTOR_FIELDS = %i[name base_url auth_type description enabled].freeze
  OPERATION_FIELDS = %i[name http_method method path summary description effect enabled cost_cents label].freeze

  rescue_from Rest::ServiceSetup::Invalid do |error|
    render json: { error: error.message, errors: error.errors }, status: :unprocessable_content
  end

  def create
    result = Rest::ServiceSetup.create!(
      project: current_project, user: current_user, connector: connector_attributes, operations: operation_attributes,
      blocks: ActiveModel::Type::Boolean.new.cast(params.fetch(:blocks, true)) != false,
      stamp: ->(record) { Authoring::Review.stamp_web!(record, current_user) }
    )
    render json: present(result), status: :created
  end

  private

  def preserved_param_paths
    operations = params[:operations].is_a?(Array) ? params[:operations] : []
    connector = params[:connector].respond_to?(:permit) ? [ %i[connector defaultHeaders], %i[connector default_headers] ] : []
    connector + operations.each_index.select { |i| operations[i].respond_to?(:permit) }
                          .flat_map { |i| [ [ :operations, i, :inputSchema ], [ :operations, i, :input_schema ] ] }
  end

  def connector_attributes
    raw = params[:connector]
    raise Rest::ServiceSetup::Invalid, "connector" => [ "Send the connector's details" ] unless raw.respond_to?(:permit)

    raw.permit(*CONNECTOR_FIELDS).to_h.merge(hash_param(raw, :auth_config), hash_param(raw, :default_headers))
  end

  def operation_attributes
    raw = params[:operations]
    return [] unless raw.is_a?(Array)

    raw.first(Rest::ServiceSetup::MAX_OPERATIONS + 1).filter_map do |operation|
      next unless operation.respond_to?(:permit)

      attributes = operation.permit(*OPERATION_FIELDS).to_h
      attributes["input_schema"] = hash_param(operation, :input_schema)["input_schema"] if operation.key?(:input_schema)
      attributes
    end
  end

  def hash_param(parameters, key)
    value = parameters[key]
    return {} unless parameters.key?(key)

    { key.to_s => value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value }
  end

  def present(result)
    { connector: { id: result.connector.id, name: result.connector.name,
                   editPath: edit_company_project_api_connector_path(current_project, result.connector) },
      operations: result.operations.map { |operation| { id: operation.id, name: operation.name } },
      blocks: result.blocks.map { |block| { id: block.id, key: "#{block.namespace}/#{block.slug}@#{block.version}",
                                            label: block.manifest["label"] } },
      warnings: result.warnings }
  end
end

# frozen_string_literal: true

class Web::Company::Projects::ApiConnectorImportsController < Web::Company::Projects::ApplicationController
  requires_feature :workflow_action_steps

  SOURCES = %w[openapi_url openapi_text curl].freeze
  MAX_DRAFTS = Rest::OpenapiImporter::MAX_OPERATIONS
  DRAFT_FIELDS = %i[name method path summary description effect].freeze

  def preview
    value = params[:value].to_s
    result = case params[:source].to_s
    when "openapi_url" then Rest::OpenapiImporter.from_url(value)
    when "openapi_text" then Rest::OpenapiImporter.from_text(value)
    when "curl" then Rest::CurlImporter.parse(value)
    else return render json: { error: "Choose where to import from." }, status: :unprocessable_content
    end

    json = result.as_json
    render json: { base_url: json["base_url"], drafts: json["operations"], warnings: json["warnings"] }
  rescue Rest::ImportError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def create
    drafts = draft_params
    return render json: { error: "Choose at least one operation to import." }, status: :unprocessable_content if drafts.empty?

    operations = drafts.map { |attrs| connector.api_operations.new(attrs) }
    errors = draft_errors(operations)

    saved = errors.empty? ? save_all(operations, errors) : 0
    if errors.empty?
      redirect_to edit_company_project_api_connector_path(current_project, connector), notice: "#{saved} operation(s) imported"
    else
      render json: { errors: errors }, status: :unprocessable_content
    end
  end

  private

  def preserved_param_paths
    count = params[:drafts].is_a?(Array) ? params[:drafts].size : 0
    (0...count).flat_map { |i| [ [ :drafts, i, :inputSchema ], [ :drafts, i, :input_schema ] ] }
  end

  def connector
    @connector ||= ApiConnector.where(scope_type: "Project", scope_id: current_project.id)
                               .unarchived.find(params[:api_connector_id])
  end

  def draft_params
    raw = params[:drafts]
    return [] unless raw.is_a?(Array)

    raw.first(MAX_DRAFTS).filter_map do |draft|
      next unless draft.respond_to?(:permit)

      attrs = draft.permit(*DRAFT_FIELDS).to_h
      schema = draft[:input_schema]
      attrs[:input_schema] = schema.respond_to?(:to_unsafe_h) ? schema.to_unsafe_h : schema if draft.key?(:input_schema)
      attrs
    end
  end

  def draft_errors(operations)
    errors = {}
    seen = Set.new
    operations.each_with_index do |operation, index|
      operation.valid?
      messages = operation.errors.full_messages
      messages += [ "Name has already been taken" ] unless seen.add?(operation.name) || operation.name.blank?
      errors[index] = messages.uniq if messages.any?
    end
    errors
  end

  def save_all(operations, errors)
    ApiOperation.transaction { operations.each(&:save!) }
    operations.size
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    index = operations.index { |op| op.errors.any? } || 0
    errors[index] = [ e.is_a?(ActiveRecord::RecordInvalid) ? e.message : "Name has already been taken" ]
    0
  end
end

# frozen_string_literal: true

class Web::Company::Projects::ApiOperationsController < Web::Company::Projects::ApplicationController
  requires_feature :workflow_action_steps

  def create
    operation = connector.api_operations.new
    assign(operation)
    operation.save!
    redirect_to back_path, notice: "Operation added"
  rescue ActiveRecord::RecordInvalid
    redirect_to back_path, inertia: { errors: operation.errors }
  end

  def update
    operation = connector.api_operations.find(params[:id])
    assign(operation)
    operation.save!
    redirect_to back_path, notice: "Operation updated"
  rescue ActiveRecord::RecordInvalid
    redirect_to back_path, inertia: { errors: operation.errors }
  end

  def destroy
    operation = connector.api_operations.find(params[:id])
    count = steps_using(operation)
    return redirect_to back_path, alert: "This operation is used by #{count} action step(s). Disable it instead." if count.positive?

    operation.destroy!
    redirect_to back_path, notice: "Operation deleted"
  end

  private

  def preserved_param_paths
    [ [ :apiOperation, :inputSchema ], [ :api_operation, :input_schema ] ]
  end

  def connector
    @connector ||= ApiConnector.where(scope_type: "Project", scope_id: current_project.id)
                               .unarchived.find(params[:api_connector_id])
  end

  def back_path
    edit_company_project_api_connector_path(current_project, connector)
  end

  def steps_using(operation)
    Step.not_deleted
        .joins(:workflow)
        .where(workflows: { scope_type: "Project", scope_id: current_project.id, deleted_at: nil })
        .where("steps.kind_config ->> 'target' = 'rest_operation' AND steps.kind_config ->> 'api_operation_id' = ?",
               operation.id.to_s)
        .count
  end

  def assign(operation)
    attrs = params.require(:api_operation)
    operation.assign_attributes(ApiOperation.with_legacy_method(attrs.permit(:name, :http_method, :method, :path, :summary,
                                                                            :description, :effect, :enabled).to_h))
    schema = attrs[:input_schema]
    operation.input_schema = schema.respond_to?(:to_unsafe_h) ? schema.to_unsafe_h : schema if attrs.key?(:input_schema)
    operation.cost_cents = attrs[:cost_cents] if attrs.key?(:cost_cents)
  end
end

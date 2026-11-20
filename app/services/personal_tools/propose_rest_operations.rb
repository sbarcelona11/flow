# frozen_string_literal: true

module PersonalTools
  class ProposeRestOperations < Base
    include RestAuthoring

    tool do
      display_name "Propose REST Operations"
      description "Propose more operations (and blocks) on a REST connector of this project. Like propose_rest_connector " \
                  "it is only a proposal: the operations are created switched off and waiting for review, and the " \
                  "connector itself does not change. A person approves them in Connectors, REST APIs."
      audience :user
      tags :rest_authoring
      param :project_id, type: :integer, description: "Project id.", required: true
      param :connector_id, type: :integer, description: "Id of a connector of this project (see list_rest_connectors).", required: true
      param :operations, type: :array, description: "At least one, at most #{Rest::ServiceSetup::MAX_OPERATIONS}.", required: true,
                         items: ProposeRestConnector::OPERATION_ITEMS
      param :blocks, type: :boolean, description: "Also propose one block per operation (default true)."
    end

    def execute
      project = authoring_project!(Web::Company::Projects::ApiServiceSetupsPolicy, :create?)
      connector = ApiConnector.for_project(project).find_by(id: params[:connector_id])
      raise Base::NotFoundError, "Connector #{Authoring::ToolText.line(params[:connector_id], max: 20)} not found in this project" unless connector

      result = Rest::ServiceSetup.create!(project: project, user: user, connector: connector, operations: operation_inputs,
                                          blocks: params[:blocks] != false, origin: tool_origin, session: session)
      success(proposal(project, result))
    rescue RestAuthoring::InvalidInput => e
      error(e.message)
    rescue Rest::ServiceSetup::Invalid => e
      error(refusal(e))
    end
  end
end

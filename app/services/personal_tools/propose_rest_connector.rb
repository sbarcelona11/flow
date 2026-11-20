# frozen_string_literal: true

module PersonalTools
  class ProposeRestConnector < Base
    include RestAuthoring

    OPERATION_ITEMS = {
      type: "object", additionalProperties: false, required: %w[name method path],
      properties: {
        name: { type: "string", description: "Operation name, lower_snake_case." },
        method: { type: "string", enum: %w[GET POST PUT PATCH DELETE] },
        path: { type: "string", description: "Path under the base URL, like /invoices/{id}." },
        effect: { type: "string", enum: Step::ACTION_EFFECTS, description: "What it does: read, write, send or irreversible. A GET is read; this can only be raised." },
        summary: { type: "string" }, description: { type: "string" }, label: { type: "string", description: "The block's label." },
        input_schema: { type: "object", description: "JSON Schema of its arguments, grouped as path, query, header and body." }
      }
    }.freeze

    tool do
      display_name "Propose REST Connector"
      description "Propose a new REST service: a connector with its operations and a block for each. It is only a " \
                  "proposal. Everything is created switched off and waiting for review, and a person approves it in " \
                  "Connectors, REST APIs. You cannot approve or enable it. `auth_config` may name only Config Items that " \
                  "already exist in the project (see list_config_items; you never see their values); never ask for or " \
                  "write a secret. The base URL must be a public https address. Tell the user what to review: the host " \
                  "and which secret goes to it."
      audience :user
      tags :rest_authoring
      param :project_id, type: :integer, description: "Project id.", required: true
      param :name, type: :string, description: "Connector name, unique in the project.", required: true
      param :base_url, type: :string, description: "Public https base URL, like https://api.example.com/v1.", required: true
      param :auth_type, type: :string, description: "How it authenticates.", enum: ApiConnector::AUTH_TYPES, required: true
      param :auth_config, type: :object,
            description: "For bearer: {config_item_name}. For api_key_header: {config_item_name, header_name}. For " \
                         "api_key_query: {config_item_name, query_param}. For basic: {username_item, password_item}. " \
                         "Names of existing Config Items only."
      param :default_headers, type: :object, description: "Plain headers sent on every call. Never a credential."
      param :description, type: :string, description: "What the service is."
      param :operations, type: :array, description: "At least one, at most #{Rest::ServiceSetup::MAX_OPERATIONS}.", required: true,
                         items: OPERATION_ITEMS
      param :blocks, type: :boolean, description: "Also propose one block per operation (default true)."
    end

    CONNECTOR_KEYS = %w[name base_url auth_type description].freeze

    def execute
      project = authoring_project!(Web::Company::Projects::ApiServiceSetupsPolicy, :create?)
      connector = params.to_h.slice(*CONNECTOR_KEYS).merge("auth_config" => hash_param(:auth_config),
                                                           "default_headers" => hash_param(:default_headers))
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

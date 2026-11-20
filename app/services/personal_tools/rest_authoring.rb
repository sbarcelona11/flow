# frozen_string_literal: true

module PersonalTools
  # What the REST and block tools share. They put an agent in front of the review gate, so each of them: refuses as
  # "not found" unless the company has workflow_action_steps; authorizes as the matching web policy does; can only
  # propose (origin `builder`/`mcp`, never `web`); and hands text that came from a spec, an API or another author back
  # labelled as data (Authoring::ToolText).
  module RestAuthoring
    InvalidInput = Class.new(StandardError)

    URL_OPTIONS = -> { { host: Settings.domain, protocol: Settings.protocol } }
    LINES = 20

    private

    def authoring_project!(policy, query)
      project = find_project!
      unless Feature.enabled?(:workflow_action_steps, company: project.company)
        raise Base::NotFoundError, "Project #{project.id} not found"
      end

      authorize!(project, query, policy: policy, project: project)
      project
    end

    def tool_origin = session&.aixle_builder? ? "builder" : "mcp"

    # The counter the matching web controller keeps, so a person's tries and their agent's draw on the same allowance.
    def throttled?(controller_path, limit)
      key = [ "rate-limit", controller_path, user.id ].join(":")
      count = Rails.cache.increment(key, 1, expires_in: 1.minute)
      count.is_a?(Integer) && count > limit
    end

    def untrusted(text, max: Authoring::ToolText::LINE_MAX) = Authoring::ToolText.untrusted(text, max: max)

    def untrusted_lines(texts, max: Authoring::ToolText::LINE_MAX)
      Array(texts).first(LINES).map { |text| untrusted(text, max: max) }
    end

    def url_helpers = Rails.application.routes.url_helpers

    def connector_review_url(project, connector)
      url_helpers.review_company_project_api_connector_url(project, connector, **URL_OPTIONS.call)
    end

    def blocks_review_url(project)
      url_helpers.company_project_module_definitions_url(project, **URL_OPTIONS.call)
    end

    def hash_param(key)
      value = params[key]
      return {} if value.nil?
      raise InvalidInput, "#{key} must be an object" unless value.respond_to?(:to_h) && !value.is_a?(Array) && !value.is_a?(String)

      value.to_h.deep_stringify_keys
    end

    def checked_text(value, label, named: false)
      problem = Authoring::ToolText.credential_problem(value, label, named: named)
      raise InvalidInput, problem if problem
    end

    def operation_inputs
      raw = params[:operations]
      raise InvalidInput, "operations must be a list" unless raw.is_a?(Array)

      raw.first(Rest::ServiceSetup::MAX_OPERATIONS + 1).map do |operation|
        raise InvalidInput, "each operation must be an object" unless operation.respond_to?(:to_h) && !operation.is_a?(String)

        operation.to_h.deep_stringify_keys.slice(*Rest::ServiceSetup::OPERATION_FIELDS, "label")
      end
    end

    def refusal(error)
      detail = error.errors.map { |key, messages| "#{key}: #{messages.join(', ')}" }.join("; ")
      "The proposal was refused: #{Authoring::ToolText.line(detail, max: 600)}"
    end

    # What a proposal answers with: ids, the state, where to review, and what the reviewer will see. Text the agent
    # wrote comes back labelled all the same, since the next reader of this answer is another model.
    def proposal(project, result)
      connector = result.connector
      { notice: Authoring::ToolText::NOTICE, status: "waiting for review", enabled: false, id: connector.id,
        connector: { id: connector.id, name: untrusted(connector.name, max: 80), host: Authoring::ToolText.line(connector.host, max: 120) },
        operations: result.operations.map { |op| { id: op.id, name: untrusted(op.name, max: 80) } },
        blocks: result.blocks.map { |block| { id: block.id, ref: "#{block.namespace}/#{block.slug}@#{block.version}" } },
        secret_goes_to: secret_lines(connector),
        review_url: connector_review_url(project, connector), blocks_review_url: blocks_review_url(project),
        warnings: untrusted_lines(result.warnings, max: 300),
        next_step: "Nothing is usable yet. Tell the user to open review_url (Connectors, REST APIs) and approve the " \
                   "connector and its operations, then the blocks in Blocks. They will confirm which secret goes to which host." }
    end

    def secret_lines(connector)
      Rest::SecretBindings.for(auth_config: connector.auth_config, base_url: connector.base_url).map do |binding|
        item, host = binding.split(" → ", 2)
        { config_item: Authoring::ToolText.line(item, max: 80), host: Authoring::ToolText.line(host, max: 120) }
      end
    end

    def state_text(record) = record.review_state == "waiting" ? "waiting for review" : record.review_state
  end
end

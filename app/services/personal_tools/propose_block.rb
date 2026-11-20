# frozen_string_literal: true

module PersonalTools
  class ProposeBlock < Base
    include RestAuthoring

    tool do
      display_name "Propose Block"
      description "Propose a block for one REST operation of this project: a named, pre-configured view of it that workflows " \
                  "can use. It is only a proposal. The block is created switched off and waiting for review, and a person " \
                  "approves it in Connectors, Blocks. Its effect can only be raised above the operation's. You cannot " \
                  "approve or enable it, and add_block_step refuses it until a person has."
      audience :user
      strict
      tags :rest_authoring
      param :project_id, type: :integer, description: "Project id.", required: true
      param :operation_id, type: :integer, description: "Id of a REST operation of this project (see list_rest_connectors).", required: true
      param :label, type: :string, description: "What the block is called in the builder.", required: true
      param :description, type: :string, description: "One or two plain sentences."
      param :settings, type: :array, description: "Argument names to expose as settings (default: all).", items: { type: "string" }
      param :effect, type: :string, description: "Raise the effect above the operation's own; a lower one is ignored.", enum: Step::ACTION_EFFECTS
    end

    def execute
      project = authoring_project!(Web::Company::Projects::ModuleDefinitionsPolicy, :create?)
      return error("Too many new blocks. Try again in a minute.") if throttled?(RestAuthoring::BLOCKS, 20)

      operation = ApiOperation.joins(:api_connector).where(api_connectors: { scope_type: "Project", scope_id: project.id, archived_at: nil })
                              .find_by(id: params[:operation_id])
      raise Base::NotFoundError, "Operation #{Authoring::ToolText.line(params[:operation_id], max: 20)} not found in this project" unless operation

      checked_text([ params[:label], params[:description], params[:settings], params[:effect] ], "the block text")
      built = Modules::BlockBuilder.from_operation(project: project, operation: operation, label: params[:label].to_s,
                                                   description: params[:description], settings: settings, effect: params[:effect])
      definition = ModuleDefinition.new(scope: project, manifest: built.manifest)
      Authoring::Review.propose!(definition, user: user, origin: tool_origin, session: session)
      success(payload(project, definition, built))
    rescue RestAuthoring::InvalidInput => e
      error(e.message)
    rescue Modules::BlockBuilder::Invalid, Modules::Manifest::Invalid, ActiveRecord::RecordInvalid => e
      error(Authoring::ToolText.quoted("The block was refused", e.message, max: 400))
    end

    private

    def settings
      raw = params[:settings]
      return nil if raw.nil?
      raise RestAuthoring::InvalidInput, "settings must be a list of names" unless raw.is_a?(Array) && raw.all?(String)

      raw
    end

    def payload(project, definition, built)
      { notice: Authoring::ToolText::NOTICE, status: "waiting for review", enabled: false, id: definition.id,
        ref: "#{definition.namespace}/#{definition.slug}@#{definition.version}",
        label: untrusted(definition.manifest["label"], max: 120), effect: definition.manifest["effect"],
        review_url: blocks_review_url(project), warnings: untrusted_lines(built.warnings, max: 300),
        next_step: "Not usable yet. Tell the user to approve it in Connectors, Blocks (and the connector it calls, if that is " \
                   "waiting too)." }
    end
  end
end

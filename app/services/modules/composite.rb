# frozen_string_literal: true

module Modules
  # A composite block is a `kind: block`, `executor: composite` manifest holding up to MAX_STEPS steps written in the
  # aggregate's step shape, keyed by graph key. Inserting it expands those into ordinary steps, so nothing at run time
  # knows about it (docs/architecture/temporal-versioning.md): the only trace is `steps.composite`.
  module Composite
    MAX_STEPS = 20
    KEY = /\A[a-z][a-z0-9_]{0,63}\z/
    PORT_TOKEN = /\{\{port:([^{}\n]*)\}\}/
    OUTPUT_TOKEN = /\{\{output:([^:{}\n]+):([^{}\n]+)\}\}/
    STEP_TOKEN = /\{\{step:([^{}\n]+)\}\}/
    DRAFT_KEY = /\Anew-[1-9]\d*\z/
    STEP_FIELDS = %w[key kind name instructions kind_config depends_on sub_steps budget_cents input_asset_specs output_asset_specs
                     agent_id tool_ids skill_ids mcp_server_ids repository_ids asset_ids config_item_ids preferred_model
                     required_agent_runtime on_failure max_retries skip_policy allow_non_interactive].freeze
    ID_LISTS = { "tool_ids" => :tools, "skill_ids" => :skills, "mcp_server_ids" => :mcp_servers, "repository_ids" => :repositories,
                 "asset_ids" => :assets, "config_item_ids" => :config_items }.freeze

    Invalid = Class.new(StandardError)

    module_function

    # Every string of a value, with a lambda able to replace it; used for arguments (whole-value ports) and text alike.
    def map_strings(value, &block) = Actions::OutputInputs.map_strings(value, &block)

    def each_string(value, &block)
      case value
      when String then yield value
      when Hash then value.each_value { |item| each_string(item, &block) }
      when Array then value.each { |item| each_string(item, &block) }
      end
    end

    # Strings a step carries that tokens may appear in: its instructions, its sub-steps' instructions and its action
    # arguments.
    def output_names(step)
      names = Array(step["output_asset_specs"]).filter_map { |spec| spec["name"] }
      names << (step.dig("kind_config", "output_name").presence || Step::ACTION_DEFAULT_OUTPUT_NAME) if step["kind"] == "action"
      names
    end
  end
end

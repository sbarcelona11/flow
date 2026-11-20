# frozen_string_literal: true

module Rest
  # One REST service in one transaction: the connector, its operations and, unless declined, one block per
  # operation. Review state is not decided here. A web caller passes `stamp:`, a callable that marks each new
  # record as made and reviewed by the signed-in person (only a web controller may do that); anything else
  # passes the tool `origin:` and every record becomes a disabled proposal.
  class ServiceSetup
    CONNECTOR_FIELDS = %w[name base_url auth_type description enabled auth_config default_headers].freeze
    OPERATION_FIELDS = %w[name http_method method path summary description effect enabled input_schema cost_cents].freeze
    CONFIG_ITEM_KEYS = %w[config_item_name username_item password_item].freeze
    MAX_OPERATIONS = OpenapiImporter::MAX_OPERATIONS

    class Invalid < StandardError
      attr_reader :errors

      # errors: { "connector" => [messages], "operations.2" => [messages], "connector.auth_config" => [...] }
      def initialize(errors)
        @errors = errors
        super(errors.values.flatten.first || "The service could not be set up")
      end
    end

    Result = Data.define(:connector, :operations, :blocks, :warnings)

    def self.create!(...) = new(...).create!

    def initialize(project:, user:, connector:, operations:, blocks: true, stamp: nil, origin: nil, session: nil)
      raise ArgumentError, "pass either stamp: (a web caller) or origin: (a tool), not both and not neither" if stamp.nil? == origin.nil?

      @project = project
      @user = user
      @stamp = stamp
      @origin = origin
      @session = session
      @connector_attributes = pick(connector, CONNECTOR_FIELDS)
      @operation_inputs = Array(operations).map { |attributes| attributes.respond_to?(:to_unsafe_h) ? attributes.to_unsafe_h : attributes.to_h }
      @blocks = blocks
      @warnings = []
    end

    def create!
      check_inputs!
      ApplicationRecord.transaction do
        connector = save(ApiConnector.new(@connector_attributes.merge(scope: @project)), "connector")
        operations = @operation_inputs.each_with_index.map do |input, index|
          save(connector.api_operations.new(operation_attributes(input)), "operations.#{index}")
        end
        blocks = @blocks ? build_blocks(operations, labels(@operation_inputs)) : []
        Result.new(connector: connector, operations: operations, blocks: blocks, warnings: @warnings)
      end
    end

    private

    def check_inputs!
      errors = {}
      errors["operations"] = [ "Choose at least one operation" ] if @operation_inputs.empty?
      errors["operations"] = [ "A service takes at most #{MAX_OPERATIONS} operations" ] if @operation_inputs.size > MAX_OPERATIONS
      errors.merge!(config_item_errors)
      raise Invalid, errors if errors.any?
    end

    def config_item_errors
      config = @connector_attributes["auth_config"]
      return {} unless config.is_a?(Hash)

      names = config.slice(*CONFIG_ITEM_KEYS).values.grep(String)
      missing = names - ConfigItem.visible_for_project(@project).where(name: names).pluck(:name)
      return {} if missing.empty?

      { "connector.auth_config" => [ "names a Config Item that does not exist in this project: #{missing.map { |name| name.first(64) }.to_sentence}" ] }
    end

    def pick(attributes, allowed)
      attributes = attributes.respond_to?(:to_unsafe_h) ? attributes.to_unsafe_h : attributes.to_h
      attributes.stringify_keys.slice(*allowed)
    end

    def operation_attributes(input)
      ApiOperation.with_legacy_method(pick(input, OPERATION_FIELDS))
    end

    def labels(inputs) = inputs.map { |input| input.stringify_keys["label"].to_s.strip.presence }

    def save(record, key)
      if @stamp
        @stamp.call(record)
        record.save!
      else
        Authoring::Review.propose!(record, user: @user, origin: @origin, session: @session)
      end
      record
    rescue ActiveRecord::RecordInvalid => e
      raise Invalid, key => e.record.errors.full_messages
    rescue ActiveRecord::RecordNotUnique
      raise Invalid, key => [ "Name has already been taken" ]
    end

    # A block that cannot be built is skipped with a warning: the service itself is fine and the block can
    # be added later from the Blocks tab. The savepoint keeps one failed insert from aborting the rest.
    def build_blocks(operations, labels)
      operations.each_with_index.filter_map do |operation, index|
        label = labels[index] || operation.summary.presence&.first(80) || operation.name.humanize
        ApplicationRecord.transaction(requires_new: true) { save(block_for(operation, label), "blocks.#{index}") }
      rescue Modules::BlockBuilder::Invalid, Modules::Manifest::Invalid, Invalid => e
        @warnings << "No block was made for #{operation.name}: #{e.message}"
        nil
      end
    end

    def block_for(operation, label)
      built = Modules::BlockBuilder.from_operation(project: @project, operation: operation, label: label)
      @warnings.concat(built.warnings.map { |warning| "#{operation.name}: #{warning}" })
      ModuleDefinition.new(scope: @project, manifest: built.manifest)
    end
  end
end

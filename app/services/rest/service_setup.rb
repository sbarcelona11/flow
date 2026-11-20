# frozen_string_literal: true

module Rest
  # One REST service in one transaction: the connector, its operations and, unless declined, one block per
  # operation. Review state is not decided here. A web caller passes `reviewer:`, the token a web controller mints
  # from the signed-in person's live session (see Authoring::Review); anything else passes the tool
  # `origin:` and every record becomes a disabled proposal. Any other object as reviewer is refused. A tool may pass an
  # existing connector of the project as `connector:` to propose more operations on it; nothing about the connector changes.
  class ServiceSetup
    CONNECTOR_FIELDS = %w[name base_url auth_type description enabled auth_config default_headers].freeze
    OPERATION_FIELDS = %w[name http_method method path summary description effect enabled input_schema cost_cents].freeze
    CONFIG_ITEM_KEYS = %w[config_item_name username_item password_item].freeze
    MAX_OPERATIONS = 200

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

    def initialize(project:, user:, connector:, operations:, blocks: true, reviewer: nil, confirmed_secret_hosts: nil, origin: nil,
                   session: nil)
      raise ArgumentError, "pass either reviewer: (a web caller) or origin: (a tool), not both and not neither" if reviewer.nil? == origin.nil?
      if reviewer && !Authoring::Review.reviewer_for?(reviewer, user)
        raise ArgumentError, "reviewer: must be the reviewer token minted from this user's web session"
      end

      if connector.is_a?(ApiConnector)
        raise ArgumentError, "operations can be added to an existing connector by a tool only" if reviewer
        raise Authoring::Review::WrongProject, "that connector belongs to another project" unless connector.scope == project
        raise Invalid, "connector" => [ "#{connector.name.first(64)} is archived" ] if connector.archived?

        @existing = connector
        connector = {}
      end
      @project = project
      @user = user
      @reviewer = reviewer
      @confirmed_secret_hosts = Array(confirmed_secret_hosts).map { |entry| normalized(entry) }
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
        connector = @existing || save(ApiConnector.new(@connector_attributes.merge(scope: @project)), "connector")
        confirm_secret_hosts(connector) unless @existing
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
      if @operation_inputs.size > MAX_OPERATIONS
        errors["operations"] = [ "A service takes at most #{MAX_OPERATIONS} operations; import fewer and add the rest later" ]
      end
      errors.merge!(config_item_errors)
      errors.merge!(confirmation_errors) if errors.empty? && @reviewer
      errors.merge!(credential_errors) if @origin
      raise Invalid, errors if errors.any?
    end

    def normalized(entry)
      entry.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?").unicode_normalize.strip
    end

    def secret_bindings
      SecretBindings.for(auth_config: @connector_attributes["auth_config"], base_url: @connector_attributes["base_url"])
    rescue Regexp::TimeoutError
      raise Invalid, "connector.base_url" => [ "can't be read" ]
    end

    # The summary screen shows which secret goes to which host; the request must repeat that line back, so the
    # person is shown what a reviewed connector will send where before it can be tried or used.
    def confirmation_errors
      expected = secret_bindings
      return {} if expected.empty? || expected.sort == @confirmed_secret_hosts.sort

      { "connector.confirmed_secret_host" => [ "Confirm where the secret goes: #{expected.join(', ')}" ] }
    end

    def confirm_secret_hosts(connector)
      bindings = secret_bindings
      return if bindings.empty? || !@reviewer

      Authoring::Review.record_secret_confirmation!(connector, user: @user, bindings: bindings, user_session: @reviewer.user_session)
    end

    # A tool may not put a credential value into any text it supplies, nor a header or setting under a credential's
    # name: a person reads these as ordinary, and a header is sent. The scan is the composite graph's.
    def credential_errors
      errors = {}
      check = lambda do |key, value, label, named: false|
        problem = Authoring::ToolText.credential_problem(value, label, named: named)
        (errors[key] ||= []) << problem if problem
      end
      attributes = @connector_attributes
      check.call("connector.default_headers", attributes["default_headers"], "default headers", named: true)
      %w[name description base_url].each { |field| check.call("connector.#{field}", attributes[field], field) }
      config = attributes["auth_config"]
      check.call("connector.auth_config", config.except(*CONFIG_ITEM_KEYS), "auth settings") if config.is_a?(Hash)
      @operation_inputs.each_with_index do |input, index|
        check.call("operations.#{index}", input.stringify_keys.slice("name", "path", "summary", "description", "label", "input_schema"),
                   "operation text")
      end
      errors
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
      if @reviewer
        @reviewer.stamp!(record)
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

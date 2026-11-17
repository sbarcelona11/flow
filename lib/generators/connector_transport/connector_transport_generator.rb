# frozen_string_literal: true

require "rails/generators"

class ConnectorTransportGenerator < Rails::Generators::NamedBase
  NAME_FORMAT = /\A[a-z][a-z0-9_]{1,31}\z/
  RESERVED_SUFFIX = /_(contract|test)\z/

  source_root File.expand_path("templates", __dir__)
  desc "Scaffolds a connector transport: its class, its contract test and its connection settings schema."

  def check_name
    raise Thor::Error, "Invalid transport name #{name.inspect}: use snake_case, 2-32 characters, starting with a letter, not ending in _contract or _test." unless name.match?(NAME_FORMAT) && !name.match?(RESERVED_SUFFIX)

    taken = taken_reason
    raise Thor::Error, "Cannot generate #{name}: #{taken}." if taken
  end

  def create_transport
    template "transport.rb.tt", transport_path
  end

  def create_contract_test
    template "contract_test.rb.tt", "test/services/connectors/transports/#{name}_contract_test.rb"
  end

  def create_config_schema
    template "config.schema.json.tt", "config/connectors/#{name}.schema.json"
  end

  def show_next_steps
    say <<~STEPS

      Manual steps, until the target list is derived from the registry:
        1. Implement the TODOs in #{transport_path}.
        2. Wire stub_backend and backend_calls in the contract test to your backend seam, then run:
           bin/rails test test/services/connectors/transports/#{name}_contract_test.rb
        3. Last, once the contract test is green (adding the target makes the transport's hooks reachable):
           add "#{target}" to Step::ACTION_TARGETS (app/models/step.rb) and '#{target}' to the type
           union in ActionTargetResource, then run bin/rails typelizer:generate.
      See docs/architecture/connector-transports.md.
    STEPS
  end

  private

  def transport_path = "app/services/connectors/transports/#{name}.rb"
  def target = "#{name}_operation"
  def class_constant = name.camelize

  def next_position
    keys = Connectors::Registry.keys
    keys.map { |key| Connectors::Registry.fetch(key).transport_position }.max.to_i + 1
  end

  def taken_reason
    if Connectors::Registry.keys.include?(name.to_sym)
      "a transport with key #{name} already exists"
    elsif Connectors::Registry.targets.include?(target)
      "the target #{target} is already registered"
    elsif Connectors::Transports.const_defined?(class_constant, false)
      "Connectors::Transports::#{class_constant} already exists"
    elsif %W[#{transport_path} test/services/connectors/transports/#{name}_contract_test.rb config/connectors/#{name}.schema.json]
          .any? { |path| File.exist?(File.join(destination_root, path)) }
      "a file for it already exists"
    end
  end
end

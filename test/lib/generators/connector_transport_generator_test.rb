# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/connector_transport/connector_transport_generator"

class ConnectorTransportGeneratorTest < Rails::Generators::TestCase
  tests ConnectorTransportGenerator
  setup :prepare_destination
  teardown { FileUtils.rm_rf(destination_root) }

  def destination_root
    @destination_root ||= File.expand_path("../../../tmp/generator_test/#{SecureRandom.hex(6)}", __dir__)
  end

  def run_generator(args = default_arguments, config = {})
    super([ *args, "--force" ], config)
  end

  test "creates the transport, its contract test and its settings schema" do
    run_generator %w[graphql]

    assert_file "app/services/connectors/transports/graphql.rb"
    assert_file "test/services/connectors/transports/graphql_contract_test.rb"
    assert_file "config/connectors/graphql.schema.json"
  end

  test "registers the transport under its key, target and the next position" do
    run_generator %w[graphql]
    position = Connectors::Registry.keys.map { |key| Connectors::Registry.fetch(key).transport_position }.max + 1

    assert_file "app/services/connectors/transports/graphql.rb" do |content|
      assert_match(/class Graphql < Transport/, content)
      assert_match(/transport :graphql, target: "graphql_operation", position: #{position}$/, content)
      assert_match(/NotImplementedError/, content)
      assert_match(/def connections\(_project\) = \[\]/, content)
    end
  end

  test "the contract test includes the contract and fails until the backend seam is wired" do
    run_generator %w[graphql]

    assert_file "test/services/connectors/transports/graphql_contract_test.rb" do |content|
      assert_match(/include Connectors::TransportContract/, content)
      assert_match(/Registry\.fetch\(:graphql\)/, content)
      assert_match(/def stub_backend\(outcome\)\n\s+raise NotImplementedError, "wire this to your backend seam/, content)
    end
  end

  test "the settings schema is a JSON Schema with a base URL, an auth type enum and a config item name" do
    run_generator %w[graphql]
    schema = JSON.parse(File.read(File.join(destination_root, "config/connectors/graphql.schema.json")))

    assert_empty SchemaHygiene.errors_for(schema)
    assert_equal %w[base_url auth_type config_item_name], schema["properties"].keys
    assert_equal %w[none bearer header], schema.dig("properties", "auth_type", "enum")
  end

  test "prints the manual steps and edits no existing file" do
    existing = File.join(destination_root, "app/models/step.rb")
    FileUtils.mkdir_p(File.dirname(existing))
    File.write(existing, "untouched")

    output = capture(:stdout) { run_generator %w[graphql] }

    assert_match(/Step::ACTION_TARGETS/, output)
    assert_match(/ActionTargetResource/, output)
    assert_match(/graphql_contract_test\.rb/, output)
    assert_equal "untouched", File.read(existing)
  end

  test "refuses names that are not snake_case of 2 to 32 characters" do
    [ "Graphql", "1sql", "g", "a-b", "x" * 33, "graphql_contract", "graphql_test" ].each do |name|
      assert_match(/Invalid transport name/, refused([ name ]))
    end
    assert_no_file "app/services/connectors/transports/graphql.rb"
  end

  test "refuses a name that is already a transport key" do
    assert_match(/transport with key rest already exists/, refused(%w[rest]))
    assert_no_file "app/services/connectors/transports/rest.rb"
  end

  test "refuses a name whose constant already exists" do
    Connectors::Transports.const_set(:GhostOne, Class.new)
    assert_match(/Connectors::Transports::GhostOne already exists/, refused(%w[ghost_one]))
    assert_no_file "app/services/connectors/transports/ghost_one.rb"
  ensure
    Connectors::Transports.send(:remove_const, :GhostOne)
  end

  test "refuses a name whose file already exists" do
    path = File.join(destination_root, "config/connectors/graphql.schema.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}")

    assert_match(/file for it already exists/, refused(%w[graphql]))
    assert_no_file "app/services/connectors/transports/graphql.rb"
  end

  private

  def refused(args)
    capture(:stderr) { run_generator args }
  end
end

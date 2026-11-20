# frozen_string_literal: true

require "test_helper"

module Rest
  class ServiceSetupTest < ActiveSupport::TestCase
    setup do
      @company = create(:company)
      @user = create(:user, company: @company)
      @project = create(:project, company: @company, owner: @user)
    end

    def reviewer = Authoring::Review.web_reviewer(user_session: UserSession.start!(user: @user))

    def connector_attributes(**overrides)
      { name: "billing", base_url: "https://api.example.com/v1", auth_type: "none", description: "Invoices" }.merge(overrides)
    end

    def operation_attributes(name = "list_invoices", **overrides)
      { name: name, http_method: "GET", path: "/#{name}", summary: "List invoices", effect: "read",
        input_schema: { "type" => "object", "properties" => { "query" => { "type" => "object",
                                                                         "properties" => { "limit" => { "type" => "integer" } } } } } }.merge(overrides)
    end

    def setup_service(operations: [ operation_attributes ], connector: connector_attributes, **options)
      ServiceSetup.create!(project: @project, user: @user, connector: connector, operations: operations, reviewer: reviewer, **options)
    end

    def counts = [ ApiConnector.count, ApiOperation.count, ModuleDefinition.count ]

    test "a web setup creates the connector, its operations and one valid block per operation, all reviewed by the person" do
      result = setup_service(operations: [ operation_attributes, operation_attributes("create_invoice", http_method: "POST", effect: "write") ])

      assert_equal %w[list_invoices create_invoice], result.operations.map(&:name)
      assert_equal 2, result.blocks.size
      (result.operations + [ result.connector ] + result.blocks).each do |record|
        assert_equal [ "web", "reviewed", true, @user ], [ record.origin, record.review_state, record.enabled, record.reviewed_by ], record.class.name
      end
      registry = Modules::Registry.new(@project)
      result.blocks.each { |block| assert_equal "valid", registry.block("#{block.namespace}/#{block.slug}@#{block.version}").status }
      assert_equal "write", result.blocks.last.manifest["effect"]
    end

    test "the block label comes from the operation's label, its summary or its name" do
      result = setup_service(operations: [ operation_attributes("a_one", label: "Look up one"), operation_attributes("b_two"),
                                           operation_attributes("c_three", summary: nil) ])

      assert_equal [ "Look up one", "List invoices", "C three" ], result.blocks.map { |block| block.manifest["label"] }
    end

    test "blocks: false creates no blocks" do
      result = setup_service(blocks: false)

      assert_empty result.blocks
      assert_equal 0, ModuleDefinition.count
      assert_equal 1, ApiOperation.count
    end

    test "an invalid operation rolls back the connector, the other operations and the blocks" do
      before = counts

      error = assert_raises(ServiceSetup::Invalid) do
        setup_service(operations: [ operation_attributes, operation_attributes("bad name", path: "no-slash") ])
      end

      assert_equal before, counts
      assert error.errors.key?("operations.1")
    end

    test "a duplicate operation name is an error on that operation and rolls everything back" do
      before = counts

      error = assert_raises(ServiceSetup::Invalid) { setup_service(operations: [ operation_attributes, operation_attributes ]) }

      assert_equal before, counts
      assert_includes error.errors.keys, "operations.1"
    end

    test "an invalid connector is an error on the connector" do
      error = assert_raises(ServiceSetup::Invalid) { setup_service(connector: connector_attributes(base_url: "http://plain.example.com")) }

      assert_includes error.errors.keys, "connector"
      assert_equal 0, ApiConnector.count
    end

    test "a Config Item the project does not have is refused on auth_config" do
      create(:config_item, scope: create(:project, company: @company, owner: @user), name: "OTHER_PROJECT_KEY", item_type: :secret, value: "v")

      error = assert_raises(ServiceSetup::Invalid) do
        setup_service(connector: connector_attributes(auth_type: "bearer", auth_config: { "config_item_name" => "OTHER_PROJECT_KEY" }))
      end

      assert_equal [ "connector.auth_config" ], error.errors.keys
      assert_match(/OTHER_PROJECT_KEY/, error.errors["connector.auth_config"].first)
      assert_equal [ 0, 0, 0 ], counts
    end

    test "a Config Item the project has is accepted, and the setup never creates one" do
      create(:config_item, scope: @project, name: "BILLING_TOKEN", item_type: :secret, value: "tok-1")
      items = ConfigItem.count

      result = setup_service(connector: connector_attributes(auth_type: "bearer", auth_config: { "config_item_name" => "BILLING_TOKEN" }),
                             confirmed_secret_hosts: [ "BILLING_TOKEN → api.example.com" ])

      assert_equal({ "config_item_name" => "BILLING_TOKEN" }, result.connector.auth_config)
      assert_equal items, ConfigItem.count
    end

    test "basic auth names are all checked" do
      create(:config_item, scope: @project, name: "BILLING_USER", item_type: :secret, value: "u")

      error = assert_raises(ServiceSetup::Invalid) do
        setup_service(connector: connector_attributes(auth_type: "basic",
                                                      auth_config: { "username_item" => "BILLING_USER", "password_item" => "MISSING_PW" }))
      end

      assert_match(/MISSING_PW/, error.errors["connector.auth_config"].first)
      assert_no_match(/BILLING_USER/, error.errors["connector.auth_config"].first)
    end

    test "needs at least one operation and at most 200" do
      assert_raises(ServiceSetup::Invalid) { setup_service(operations: []) }
      error = assert_raises(ServiceSetup::Invalid) { setup_service(operations: Array.new(201) { |i| operation_attributes("op_#{i}") }) }
      assert_match(/at most 200/, error.message)
    end

    test "only the permitted attributes are read" do
      result = setup_service(connector: connector_attributes(origin: "mcp", reviewed_by_id: 0, scope_id: 0, archived_at: Time.current),
                             operations: [ operation_attributes(origin: "mcp", api_connector_id: 0, rejected_at: Time.current) ])

      assert_equal [ "web", @project ], [ result.connector.origin, result.connector.scope ]
      assert_equal [ "web", result.connector.id ], [ result.operations.sole.origin, result.operations.sole.api_connector_id ]
      assert_nil result.connector.archived_at
      assert_nil result.operations.sole.rejected_at
    end

    test "a tool origin proposes everything disabled and waiting, with an audit row each, and no block resolves" do
      result = ServiceSetup.create!(project: @project, user: @user, origin: "builder", connector: connector_attributes(enabled: true),
                                    operations: [ operation_attributes(enabled: true) ])

      records = [ result.connector, *result.operations, *result.blocks ]
      assert_equal 3, records.size
      records.each do |record|
        assert_equal [ "builder", "waiting", false ], [ record.origin, record.review_state, record.enabled ], record.class.name
      end
      assert_equal 3, Audit.where(action: "authoring.proposed").count
      block = result.blocks.sole
      assert_raises(Modules::Registry::Unknown) { Modules::Registry.new(@project).block("#{block.namespace}/#{block.slug}@#{block.version}") }
    end

    test "it needs either a web reviewer or a tool origin" do
      assert_raises(ArgumentError) { ServiceSetup.create!(project: @project, user: @user, connector: connector_attributes, operations: [ operation_attributes ]) }
      assert_raises(ArgumentError) do
        ServiceSetup.create!(project: @project, user: @user, connector: connector_attributes, operations: [ operation_attributes ],
                             reviewer: reviewer, origin: "builder")
      end
      assert_raises(ActiveRecord::RecordInvalid, ArgumentError) do
        ServiceSetup.create!(project: @project, user: @user, origin: "web", connector: connector_attributes, operations: [ operation_attributes ])
      end
    end

    test "a block that cannot be built is skipped with a warning and the service is kept" do
      Modules::BlockBuilder.stubs(:from_operation).raises(Modules::BlockBuilder::Invalid, "nothing to build")

      result = setup_service

      assert_equal 1, ApiOperation.count
      assert_empty result.blocks
      assert(result.warnings.any? { |warning| warning.include?("list_invoices") && warning.include?("nothing to build") })
    end

    test "a lambda, a hash or any other object is refused as the reviewer" do
      forging = ->(record) { record.assign_attributes(origin: "builder", reviewed_at: Time.current) }

      [ forging, { reviewed: true }, Object.new, nil ].each do |fake|
        assert_raises(ArgumentError) do
          ServiceSetup.create!(project: @project, user: @user, connector: connector_attributes(enabled: true),
                               operations: [ operation_attributes ], reviewer: fake)
        end
      end
      assert_equal [ 0, 0, 0 ], counts
    end

    test "the reviewer must be the person the service is created for" do
      other = create(:user, company: @company)
      session = UserSession.start!(user: other)

      assert_raises(ArgumentError) do
        ServiceSetup.create!(project: @project, user: @user, connector: connector_attributes, operations: [ operation_attributes ],
                             reviewer: Authoring::Review.web_reviewer(user_session: session))
      end
    end

    test "a reviewer cannot be minted without a live web session" do
      assert_raises(ArgumentError) { Authoring::Review.web_reviewer(user_session: nil) }
      assert_raises(ArgumentError) { Authoring::Review.web_reviewer(user_session: @user) }
      assert_raises(NoMethodError) { Authoring::Review::WebReviewer.new(@user, nil) }
    end

    def secured(**overrides)
      create(:config_item, scope: @project, name: "BILLING_TOKEN", item_type: :secret, value: "tok")
      connector_attributes(auth_type: "bearer", auth_config: { "config_item_name" => "BILLING_TOKEN" }, **overrides)
    end

    test "naming a secret needs the person's confirmation of which host it goes to" do
      attributes = secured

      error = assert_raises(ServiceSetup::Invalid) { setup_service(connector: attributes) }
      assert_equal [ "connector.confirmed_secret_host" ], error.errors.keys
      assert_includes error.errors.values.flatten.first, "BILLING_TOKEN → api.example.com"

      wrong = assert_raises(ServiceSetup::Invalid) { setup_service(connector: attributes, confirmed_secret_hosts: [ "BILLING_TOKEN → evil.example.com" ]) }
      assert_includes wrong.errors["connector.confirmed_secret_host"].first, "api.example.com"
      assert_equal 0, ApiConnector.count
    end

    test "a confirmed secret and host is accepted and audited without a value" do
      result = setup_service(connector: secured, confirmed_secret_hosts: [ "BILLING_TOKEN → api.example.com" ])

      row = Audit.find_by!(action: "authoring.secret_bound", auditable: result.connector)
      assert_equal [ @user, [ "BILLING_TOKEN → api.example.com" ] ], [ row.user, row.audited_changes["bindings"] ]
      assert_not_includes row.audited_changes.to_json, "\"tok\""
    end

    test "a connector with no secret needs no confirmation" do
      setup_service

      assert_equal 0, Audit.where(action: "authoring.secret_bound").count
    end

    test "a tool proposal that carries a credential value in a header, description, summary or label is refused" do
      key = "sk_live_abcdefghijklmnop1234"
      cases = {
        "connector.default_headers" => [ connector_attributes(default_headers: { "X-Client" => key }), [ operation_attributes ] ],
        "connector.description" => [ connector_attributes(description: key), [ operation_attributes ] ],
        "operations.0" => [ connector_attributes, [ operation_attributes(summary: key) ] ],
        "operations.0 " => [ connector_attributes, [ operation_attributes(label: key) ] ]
      }

      cases.each do |key_name, (connector, operations)|
        error = assert_raises(ServiceSetup::Invalid, key_name) do
          ServiceSetup.create!(project: @project, user: @user, origin: "builder", connector: connector, operations: operations)
        end
        assert_includes error.errors.keys, key_name.strip
        assert_not_includes error.message, key
      end
      assert_equal [ 0, 0, 0 ], counts
    end

    test "a reviewer whose web session has since ended no longer stamps" do
      session = UserSession.start!(user: @user)
      token = Authoring::Review.web_reviewer(user_session: session)
      session.update_columns(revoked_at: Time.current)

      assert_raises(ArgumentError) do
        ServiceSetup.create!(project: @project, user: @user, connector: connector_attributes, operations: [ operation_attributes ], reviewer: token)
      end
      assert_equal [ 0, 0, 0 ], counts
    end

    test "an unreadable confirmation is a validation error, never an exception" do
      attributes = secured

      error = assert_raises(ServiceSetup::Invalid) { setup_service(connector: attributes, confirmed_secret_hosts: [ "BILLING_TOKEN \xFF api.example.com".b ]) }

      assert_equal [ "connector.confirmed_secret_host" ], error.errors.keys
    end

    test "a base URL the parser gives up on is a validation error" do
      attributes = secured
      URI.stubs(:parse).raises(Regexp::TimeoutError)

      error = assert_raises(ServiceSetup::Invalid) { setup_service(connector: attributes, confirmed_secret_hosts: [ "BILLING_TOKEN → api.example.com" ]) }

      assert_includes error.errors.keys, "connector.base_url"
    end
  end
end

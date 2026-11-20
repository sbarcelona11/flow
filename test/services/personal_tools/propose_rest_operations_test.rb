# frozen_string_literal: true

require "test_helper"

module PersonalTools
  class ProposeRestOperationsTest < ActiveSupport::TestCase
    setup do
      build_authoring_world
      @connector = create(:api_connector, scope: @project, name: "billing", auth_type: "bearer", auth_config: { "config_item_name" => "BILLING_TOKEN" })
    end

    def propose(connector_id = @connector.id, **overrides)
      run_tool(ProposeRestOperations, { connector_id: connector_id, operations: [ operation_spec("get_invoice", path: "/invoices/latest") ] }.merge(overrides))
    end

    test "adds disabled, unreviewed operations and blocks to a reviewed connector without changing it" do
      before = @connector.reload.attributes

      body = assert_ok(propose)

      operation = ApiOperation.find(body["operations"].sole["id"])
      assert_equal [ @connector, "builder", @builder.id, "waiting", false ],
                   [ operation.api_connector, operation.origin, operation.origin_session_id, operation.review_state, operation.enabled ]
      assert_equal "waiting", ModuleDefinition.find(body["blocks"].sole["id"]).review_state
      assert Audit.exists?(auditable: operation, action: "authoring.proposed")
      assert_equal before, @connector.reload.attributes
      assert @connector.enabled
    end

    test "a connector of another project is not found, and so is an archived one" do
      foreign = create(:api_connector, scope: create(:project, company: @company, owner: @user), name: "theirs")
      @connector.update!(archived_at: Time.current)
      before = ApiOperation.count

      assert_raises(PersonalTools::Base::NotFoundError) { propose(foreign.id) }
      assert_raises(PersonalTools::Base::NotFoundError) { propose(@connector.id) }
      assert_equal before, ApiOperation.count
    end

    test "a credential in an operation is refused" do
      assert_refused(propose(operations: [ operation_spec(description: "send Bearer abcdefghijklmnop") ]), /credential/)
      assert_equal 0, ApiOperation.count
    end

    test "an operation name that is taken is refused with a clear reason" do
      create(:api_operation, api_connector: @connector, name: "get_invoice")

      assert_refused(propose, /already been taken|Name/)
    end
  end
end

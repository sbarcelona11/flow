# frozen_string_literal: true

require "test_helper"

module Tools
  class BuilderToolsetTest < ActiveSupport::TestCase
    REST_TOOLS = %w[list_rest_connectors preview_rest_import propose_rest_connector propose_rest_operations
                    test_rest_operation list_blocks propose_block add_block_step].freeze

    setup { build_authoring_world }

    def served = BuilderToolset.definitions.map { |definition| definition.name.to_s }

    test "the Builder is served the new tools and still not the config item or custom tool writers" do
      assert_empty REST_TOOLS - served
      assert_empty BuilderToolset::EXCLUDED & served
      assert_equal %w[create_config_item update_config_item delete_config_item create_custom_tool update_custom_tool delete_custom_tool
                      update_project_settings], BuilderToolset::EXCLUDED
    end

    test "no tool the Builder or a personal token is served can approve, reject, enable, archive or update a connector, operation or block" do
      gate = /approve|reject|enable|disable|\Areview_|archive_(rest|api|connector|operation|block|module)|(update|delete)_(rest|api|connector|operation|block|module)/
      reaching = Registry.for_audience(:user).map { |definition| definition.name.to_s }.grep(gate) - %w[approve_step_run reject_step_run]
      assert_empty reaching, "tools that could reach the review gate: #{reaching.join(', ')}"

      tagged = Registry.tagged(:rest_authoring).map { |definition| definition.name.to_s }
      assert_equal REST_TOOLS.sort, tagged.sort
    end

    test "the tools' source never names the review gate" do
      sources = REST_TOOLS.map { |name| Rails.root.join("app/services/personal_tools/#{name}.rb").read } +
                [ Rails.root.join("app/services/personal_tools/rest_authoring.rb").read, Rails.root.join("app/services/modules/block_insertion.rb").read ]

      sources.each do |source|
        assert_no_match(/approve!|reject!|archive!|stamp_web!|web_reviewer|WebReviewer|reviewed_at|reviewed_by|enabled:\s*true|update_all|update_columns/, source)
      end
    end

    test "every tool refuses as not found for a company without action steps" do
      FeatureFlag.find_by!(key: "workflow_action_steps").overrides.update_all(enabled: false)
      Current.feature_snapshot = nil

      REST_TOOLS.each do |name|
        result = BuilderToolset.execute(Registry.fetch(name), { source: "curl", value: "curl https://a.example.com", workflow_id: 1, ref: "a/b@1", base_version: 1,
                                                                  connector_id: 1, operation_id: 1, label: "x", name: "x", base_url: "https://a.example.com",
                                                                  auth_type: "none", operations: [ operation_spec ] }, @builder)
        assert_refused(result, /not found/)
      end
    end

    test "a proposal is recorded in the session's activity" do
      BuilderToolset.execute(Registry.fetch("propose_rest_connector"), connector_params, @builder)

      activity = @builder.reload.metadata["builder_activities"].last
      assert_equal [ "propose_rest_connector", "ApiConnector" ], activity.values_at("action", "entity_type")
      assert_equal ApiConnector.last.id, activity["entity_id"]
      assert_nil activity["entity_name"]
    end

    test "a read-only tool leaves no activity" do
      BuilderToolset.execute(Registry.fetch("list_rest_connectors"), {}, @builder)

      assert_nil @builder.reload.metadata["builder_activities"]
    end

    test "the Builder cannot step outside its project by passing another project_id" do
      sibling = create(:project, company: @company, owner: @user)
      create(:api_connector, scope: sibling, name: "sibling-only")

      body = JSON.parse(BuilderToolset.execute(Registry.fetch("list_rest_connectors"), { project_id: sibling.id }, @builder)[:stdout])

      assert_empty body["connectors"]
    end

    test "the project id is not a parameter the Builder is shown" do
      schema = BuilderToolset.input_schema(Registry.fetch("propose_rest_connector"))

      assert_not_includes schema["properties"].keys, "project_id"
    end

    test "tool results never carry a secret value, a rejected value or an unlabelled spec text across the whole flow" do
      results = []
      results << run_tool(PersonalTools::ProposeRestConnector, connector_params)
      results << run_tool(PersonalTools::ListRestConnectors, {})
      results << run_tool(PersonalTools::ListBlocks, {})
      results << run_tool(PersonalTools::PreviewRestImport, { source: "curl", value: "curl https://api.example.com/v1/x -H 'Authorization: Bearer #{SECRET_VALUE}'" })

      assert_no_secret(*results)
    end

    test "the role text tells the agent what it may propose and to never ask for a secret" do
      role = ContextBuilders::AixleBuilder.new(@builder).build.find { |section| section.tag == "aixle_builder_role" }.content.squish

      assert_includes role, "propose REST connectors, operations and"
      assert_includes role, "Never ask for a secret value"
      assert_includes role, "untrusted_text"
      assert_includes role, "Connectors → REST APIs / Blocks"
    end
  end
end

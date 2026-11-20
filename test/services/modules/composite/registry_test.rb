# frozen_string_literal: true

require "test_helper"

module Modules
  module Composite
    class RegistryTest < ActiveSupport::TestCase
      include CompositeHelper

      setup do
        build_composite_project
        build_pipeline
        @manifest = Extractor.new(workflow: @workflow, step_ids: [ @summarise.id, @approve.id, @send.id ], label: "Invoice flow").manifest.manifest
      end

      def entry(manifest = @manifest, key: "local/invoice-flow@1")
        stamp_composite(manifest)
        Registry.new(@project).block(key)
      end

      test "a composite of this project's own rows is valid and lists its ports" do
        found = entry

        assert_equal [ "valid", "composite" ], [ found.status, found.executor ]
        assert_equal %w[fetch_invoice_invoice], found.ports["in"].keys
      end

      test "a composite naming another project's operation, tool or agent is invalid" do
        stranger = create(:project, company: @company, owner: @user)
        foreign_op = create(:api_operation, api_connector: create(:api_connector, scope: stranger, name: "x"))
        manifest = @manifest.deep_dup
        manifest["graph"]["steps"][2]["kind_config"]["api_operation_id"] = foreign_op.id
        definition = build(:module_definition, scope: @project, kind: "block", namespace: "local", slug: "invoice-flow", manifest: manifest)
        definition.save!(validate: false)

        found = Registry.new(@project).block("local/invoice-flow@1")

        assert_equal "invalid", found.status
        assert_match(/REST operation #{foreign_op.id}/, found.reason)
      end

      test "a composite naming another project's agent or skill is invalid" do
        stranger = create(:project, company: @company, owner: @user)
        agent = create(:agent, scope: stranger)
        manifest = @manifest.deep_dup
        manifest["graph"]["steps"][0]["agent_id"] = agent.id
        build(:module_definition, scope: @project, kind: "block", namespace: "local", slug: "invoice-flow", manifest: manifest).save!(validate: false)

        found = Registry.new(@project).block("local/invoice-flow@1")

        assert_equal "invalid", found.status
        assert_match(/agents ids outside this project/, found.reason)
      end

      test "an action step that names a composite block is invalid (no nesting)" do
        inner = @manifest.deep_dup.merge("slug" => "inner")
        stamp_composite(inner)
        manifest = @manifest.deep_dup
        manifest["graph"]["steps"][2]["kind_config"]["block"] = "local/inner@1"

        found = entry(manifest)

        assert_equal "invalid", found.status
        assert_match(/cannot hold another composite/, found.reason)
      end

      test "an action step that names an unknown block is invalid" do
        manifest = @manifest.deep_dup
        manifest["graph"]["steps"][2]["kind_config"]["block"] = "local/ghost@1"

        assert_match(/does not have/, entry(manifest).reason)
      end

      test "a missing port type is invalid" do
        manifest = @manifest.deep_dup
        manifest["ports"]["in"]["fetch_invoice_invoice"]["type"] = "local/ghost@1"

        assert_equal "invalid", entry(manifest).status
      end
    end
  end
end

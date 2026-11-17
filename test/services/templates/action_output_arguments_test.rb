# frozen_string_literal: true

require "test_helper"

class Templates::ActionOutputArgumentsTest < ActiveSupport::TestCase
  setup do
    @user = create(:user, :employee, :onboarding_completed)
    @company = @user.companies.first
    @project = create(:project, company: @company, owner: @user)
  end

  def definition(arguments: { "body" => "{{output:collect:summary.md}} and {{output:collect:summary.md}}" }, action: {}, collect: {})
    {
      "format_version" => 1, "namespace" => "acme", "slug" => "mailer", "version" => 1, "name" => "Mailer",
      "mcp_servers" => [ { "key" => "mail", "custom" => { "name" => "Mail", "transport" => "http", "url" => "https://mcp.mail.example/mcp" } } ],
      "agents" => [ { "key" => "writer", "name" => "writer", "title" => "Writer", "persona" => "Writes." } ],
      "workflows" => [ { "key" => "flow", "name" => "Flow", "steps" => [
        { "key" => "collect", "name" => "Collect", "agent" => "writer", "instructions" => "Write it.",
          "output_asset_specs" => [ { "name" => "summary.md" } ] }.merge(collect),
        { "key" => "post", "name" => "Post", "kind" => "action", "depends_on" => [ "collect" ],
          "kind_config" => { "target" => "mcp_tool", "mcp_server" => "mail", "tool" => "post", "effect" => "write",
                             "arguments" => arguments } }.merge(action)
      ] } ]
    }
  end

  def catalog_template(package) = CatalogTemplate.new.assign_package(package, commit_sha: SecureRandom.hex(20)).tap(&:save!)

  def install(definition, target: { project: @project })
    with_feature(:workflow_action_steps, true, company: @company) do
      Templates::Installer.new(catalog_template: catalog_template(Templates::Package.new(definition: definition)),
                               user: @user, target: target, idempotency_key: SecureRandom.hex(4)).apply
    end
  end

  def export(project)
    with_feature(:workflow_action_steps, true, company: @company) do
      Templates::Exporter.new(project: project, namespace: "acme", slug: "exported", name: "Exported").call
    end
  end

  test "an install turns package keys in action arguments into the new step ids" do
    install(definition)

    steps = @project.workflows.sole.steps.not_deleted.order(:position)
    collect, post = steps.to_a
    assert_equal "{{output:#{collect.id}:summary.md}} and {{output:#{collect.id}:summary.md}}",
                 post.kind_config.dig("arguments", "body")
  end

  test "an export carries the tokens as package keys and installs again the same way" do
    install(definition)

    exported = export(@project).package.definition["workflows"].sole["steps"]
    collect_key = exported.find { |step| step["name"] == "Collect" }["key"]
    post = exported.find { |step| step["name"] == "Post" }

    assert_equal "{{output:#{collect_key}:summary.md}} and {{output:#{collect_key}:summary.md}}",
                 post.dig("kind_config", "arguments", "body")
    again = create(:project, company: @company, owner: @user)
    install(export(@project).package.definition, target: { project: again })
    collect, copied = again.workflows.sole.steps.not_deleted.order(:position).to_a
    assert_equal "{{output:#{collect.id}:summary.md}} and {{output:#{collect.id}:summary.md}}", copied.kind_config.dig("arguments", "body")
  end

  test "the package is refused when a token names an unknown, later or undeclared step output" do
    {
      { "body" => "{{output:ghost:summary.md}}" } => /action arguments: unknown key ghost/,
      { "body" => "{{output:collect:other.md}}" } => /does not declare as an output/
    }.each do |arguments, message|
      error = assert_raises(Templates::Validator::InvalidPackage) do
        Templates::Validator.validate!(Templates::Package.new(definition: definition(arguments: arguments)))
      end
      assert_match message, error.message
    end

    no_edge = definition(action: { "depends_on" => [] })
    error = assert_raises(Templates::Validator::InvalidPackage) { Templates::Validator.validate!(Templates::Package.new(definition: no_edge)) }
    assert_match(/does not run before it/, error.message)
  end

  test "a package action carrying a block is refused by the package schema" do
    with_block = definition
    with_block["workflows"].first["steps"].last["kind_config"]["block"] = "acme/lookup@1"

    error = assert_raises(Templates::Validator::InvalidPackage) { Templates::Validator.validate!(Templates::Package.new(definition: with_block)) }

    assert_match(/block/, error.message)
  end
end

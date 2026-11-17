# frozen_string_literal: true

require "test_helper"

class Templates::ExporterTest < ActiveSupport::TestCase
  setup do
    @user = create(:user, :employee, :onboarding_completed)
    @company = @user.companies.first
    create(:tool, :system, name: "board_add_comment")
    package = Templates::Package.from_directory(Rails.root.join("test/fixtures/files/templates/dev-team-sdlc"))
    @source = install(package, secrets: { "SENTRY_TOKEN" => "tok-1" }).project
  end

  def install(package, key: SecureRandom.hex(4), **options)
    template = CatalogTemplate.new.assign_package(package, commit_sha: SecureRandom.hex(20)).tap(&:save!)
    Templates::Installer.new(catalog_template: template, user: @user, target: { company: @company },
                             idempotency_key: key, **options).apply
  end

  def export(project = @source, **options)
    Templates::Exporter.new(project: project, namespace: "acme", slug: "exported", name: "Exported", include_assets: true, **options).call
  end

  test "an installed template exports to a valid package that installs again the same way" do
    result = export

    definition = result.package.definition
    assert_equal "project", result.package.kind
    assert_equal({ "name" => "SENTRY_ORG", "value" => "acme" }, definition["variables"].find { |v| v["name"] == "SENTRY_ORG" })
    assert_equal [ "SENTRY_TOKEN" ], definition.dig("requires", "secrets").pluck("name")
    assert_not_includes result.template_yaml, "tok-1"
    registry = definition["skills"].find { |s| s["registry"] }
    assert_equal "acme/skills@code-review", registry["registry"]
    assert_equal "app.linear/linear", definition["mcp_servers"].find { |s| s["connector"] }.dig("connector", "name")
    assert_equal [ "platform" ], definition["tools"].select { |t| t["platform"] }.map { |t| t.keys - [ "key" ] }.flatten.uniq
    assert_equal %w[column schedule], definition["triggers"].pluck("kind")
    assert_equal "manual", definition["triggers"].first["trigger_mode"], "exports what the project runs now"

    copy = install(result.package).project
    assert_equal @source.board.board_columns.pluck(:name), copy.board.board_columns.pluck(:name)
    assert_equal @source.workflows.sole.steps.order(:position).pluck(:name, :instructions),
                 copy.workflows.sole.steps.order(:position).pluck(:name, :instructions)
    assert_equal @source.agents.pluck(:name, :persona), copy.agents.pluck(:name, :persona)
  end

  test "an exported approval step installs as an approval step" do
    config = { "timeout_seconds" => 3600, "on_timeout" => "skip" }
    @source.workflows.sole.steps.create!(name: "Sign off", position: 99, kind: "approval", kind_config: config)

    result = export

    exported = result.package.definition["workflows"].sole["steps"].find { |s| s["name"] == "Sign off" }
    assert_equal "approval", exported["kind"]
    assert_equal config, exported["kind_config"]
    assert_nil exported["agent"]

    gate = install(result.package).project.workflows.sole.steps.find_by!(name: "Sign off")
    assert_equal "approval", gate.kind
    assert_equal config, gate.kind_config
  end

  test "references travel as package keys and come back as the copy's ids" do
    workflow = @source.workflows.sole
    first, second = workflow.steps.order(:position).to_a.first(2)
    sentry = @source.mcp_servers.find_by!(name: "Sentry")
    skill = @source.skills.find_by!(name: "house-style")
    org = @source.config_items.find_by!(name: "SENTRY_ORG")
    board_tool = Tool.find_by!(name: "board_add_comment")
    first.update!(output_asset_specs: [ { "name" => "triage.md" } ])
    second.update!(mcp_server_ids: second.mcp_server_ids | [ sentry.id ], depends_on_step_ids: [ first.id ],
                   skill_ids: second.skill_ids | [ skill.id ], config_item_ids: second.config_item_ids | [ org.id ],
                   tool_ids: second.tool_ids | [ board_tool.id ],
                   instructions: "Read {{output:#{first.id}:triage.md}} from {{step:#{first.id}}}; ask {{mcp:#{sentry.id}}}. " \
                                 "Use {{skill:#{skill.id}}}, {{tool:#{board_tool.id}}} and {{config_item:#{org.id}}}.")

    result = export
    exported = result.package.definition["workflows"].sole["steps"].find { |step| step["name"] == second.name }

    assert_match(/\ARead \{\{output:[a-z][a-z0-9_]*:triage\.md\}\} from \{\{step:[a-z][a-z0-9_]*\}\}; ask \{\{mcp:[a-z][a-z0-9_]*\}\}\. /,
                 exported["instructions"])
    assert_match(/Use \{\{skill:house_style\}\}, \{\{tool:board_add_comment\}\} and \{\{config_item:SENTRY_ORG\}\}\.\z/,
                 exported["instructions"])

    copy = install(result.package).project
    copy_first, copy_second = copy.workflows.sole.steps.order(:position).to_a.first(2)
    copy_sentry = copy.mcp_servers.find_by!(name: "Sentry")
    copy_skill = copy.skills.find_by!(name: "house-style")
    copy_org = copy.config_items.find_by!(name: "SENTRY_ORG")
    assert_equal "Read {{output:#{copy_first.id}:triage.md}} from {{step:#{copy_first.id}}}; ask {{mcp:#{copy_sentry.id}}}. " \
                 "Use {{skill:#{copy_skill.id}}}, {{tool:#{board_tool.id}}} and {{config_item:#{copy_org.id}}}.",
                 copy_second.instructions
  end

  test "an action step on an MCP tool exports by server key and installs onto the new server" do
    workflow = @source.workflows.sole
    sentry = @source.mcp_servers.find_by!(name: "Sentry")
    snapshot = build(:mcp_server, :with_tool_schemas,
                     snapshot_tools: [ { "name" => "resolve_issue", "annotations" => { "destructiveHint" => true } } ])
    sentry.update!(tool_snapshot: snapshot.tool_snapshot, tool_snapshot_at: Time.current)
    run_tests = @source.tools.find_by!(name: "run_tests")

    with_feature(:workflow_action_steps, true, company: @company) do
      gate = workflow.steps.create!(name: "Sign off", position: 10, kind: "approval", kind_config: { "timeout_seconds" => 3600 })
      workflow.steps.create!(name: "Resolve", position: 11, kind: "action", depends_on_step_ids: [ gate.id ],
                             kind_config: { "target" => "mcp_tool", "mcp_server_id" => sentry.id, "tool" => "resolve_issue",
                                            "arguments" => { "id" => "{{context:issue.id}}" }, "effect" => "irreversible" })
      workflow.steps.create!(name: "Test", position: 12, kind: "action",
                             kind_config: { "target" => "wrapper", "tool_id" => run_tests.id, "effect" => "write" })

      result = export

      steps = result.package.definition["workflows"].sole["steps"].index_by { |step| step["name"] }
      assert_equal({ "target" => "mcp_tool", "mcp_server" => "sentry", "tool" => "resolve_issue",
                     "arguments" => { "id" => "{{context:issue.id}}" }, "effect" => "irreversible", "output_name" => "result.json" },
                   steps["Resolve"]["kind_config"])
      assert_equal [ "sign_off" ], steps["Resolve"]["depends_on"]
      assert_equal({ "target" => "wrapper", "tool" => "run_tests", "arguments" => {}, "effect" => "write",
                     "output_name" => "result.json" }, steps["Test"]["kind_config"])

      copy = install(result.package).project
      copy_steps = copy.workflows.sole.steps.index_by(&:name)
      copy_sentry = copy.mcp_servers.find_by!(name: "Sentry")
      assert_not_equal sentry.id, copy_sentry.id
      assert_equal({ "target" => "mcp_tool", "mcp_server_id" => copy_sentry.id, "tool" => "resolve_issue",
                     "arguments" => { "id" => "{{context:issue.id}}" }, "effect" => "irreversible", "output_name" => "result.json" },
                   copy_steps["Resolve"].kind_config)
      assert_equal [ copy_steps["Sign off"].id ], copy_steps["Resolve"].depends_on_step_ids
      assert_equal copy.tools.find_by!(name: "run_tests").id, copy_steps["Test"].kind_config["tool_id"]
    end
  end

  test "an action whose server is gone aborts the export instead of carrying its id" do
    sentry = @source.mcp_servers.find_by!(name: "Sentry")
    snapshot = build(:mcp_server, :with_tool_schemas, snapshot_tools: [ { "name" => "search" } ])
    sentry.update!(tool_snapshot: snapshot.tool_snapshot, tool_snapshot_at: Time.current)
    with_feature(:workflow_action_steps, true, company: @company) do
      action = @source.workflows.sole.steps.create!(
        name: "Search", position: 10, kind: "action",
        kind_config: { "target" => "mcp_tool", "mcp_server_id" => sentry.id, "tool" => "search", "effect" => "write" }
      )
      action.update_column(:kind_config, action.kind_config.merge("mcp_server_id" => 0))

      error = assert_raises(Templates::Exporter::ExportError) { export }

      assert_match(/step Search: MCP server 0 no longer exists/, error.message)
    end
  end

  test "export refuses a workflow with a REST action" do
    operation = create(:api_operation, api_connector: create(:api_connector, scope: @source))
    with_feature(:workflow_action_steps, true, company: @company) do
      @source.workflows.sole.steps.create!(
        name: "Charge", position: 10, kind: "action",
        kind_config: { "target" => "rest_operation", "api_operation_id" => operation.id, "effect" => "read" }
      )

      error = assert_raises(Templates::Exporter::ExportError) { export }

      assert_match(/Workflows with REST connector actions can't be exported yet\./, error.message)
    end
  end

  test "a skill's extra files travel with it" do
    skill = @source.skills.find_by!(name: "house-style")
    skill.update!(files: skill.files.merge("examples/good.rb" => "def small = 1\n"))

    result = export
    entry = result.package.section("skills").find { |s| s["path"] }

    assert_equal [ "examples/good.rb" ], entry["files"].pluck("path")
    copy = install(result.package).project.skills.find_by!(name: "house-style")
    assert_equal "def small = 1\n", copy.files["examples/good.rb"]
  end

  test "a literal MCP header value aborts the export and names the server" do
    @source.mcp_servers.find_by!(name: "Sentry").update!(headers: { "Authorization" => "Bearer sk-live-123" })

    error = assert_raises(Templates::Exporter::ExportError) { export }

    assert_match(/MCP server Sentry: Authorization holds a literal value/, error.message)
  end

  test "a stdio server written before packages had to be pinned aborts the export and names the fix" do
    files = create(:mcp_server, :stdio_transport, name: "Files", scope: @source, command: "npx", args: [ "@acme/files-mcp@1.4.0" ])
    files.update_columns(args: [ "@acme/files-mcp" ])
    step = @source.workflows.sole.steps.order(:position).first
    step.update!(mcp_server_ids: step.mcp_server_ids | [ files.id ])

    error = assert_raises(Templates::Exporter::ExportError) { export }

    assert_match(%r{mcp server Files command: must pin @acme/files-mcp to an exact version}, error.message)
  end

  test "an image that is not pinned by digest aborts the export" do
    @source.tools.find_by!(name: "run_tests").update!(docker_image: "ghcr.io/acme/runner:latest")

    error = assert_raises(Templates::Exporter::ExportError) { export }
    assert_match(/not pinned by digest/, error.message)
  end

  test "a Kiro step with a reasoning effort exports to a valid package and installs with it" do
    step = @source.workflows.sole.steps.order(:position).first
    step.update!(required_agent_runtime: "kiro_cli", preferred_model: "claude-opus-5.5", reasoning_effort: "high")

    result = export

    exported = result.package.definition["workflows"].first["steps"].first
    assert_equal %w[kiro_cli claude-opus-5.5 high],
                 exported.values_at("required_agent_runtime", "preferred_model", "reasoning_effort")
    copied = install(result.package).project.workflows.sole.steps.order(:position).first
    assert_equal %w[kiro_cli claude-opus-5.5 high],
                 [ copied.required_agent_runtime, copied.preferred_model, copied.reasoning_effort ]
  end

  test "inherit_all_project_resources is flattened into explicit lists" do
    workflow = @source.workflows.sole
    workflow.update!(config: workflow.config.merge("inherit_all_project_resources" => true))

    result = export

    base = result.package.definition["workflows"].first["base"]
    assert_equal @source.mcp_servers.count, base["mcp_servers"].size
    assert(result.notes.any? { |note| note.include?("inherited every project resource") })
  end

  test "a single agent exports on its own as an agent template" do
    agent = @source.agents.find_by!(name: "architect")

    result = export(workflow_ids: [], agent_ids: [ agent.id ], include_board: false, include_assets: false)

    assert_equal "agent", result.package.kind
    assert_equal [ "architect" ], result.package.section("agents").pluck("name")
    assert_empty result.package.section("workflows")
  end

  test "exporting some workflows without the board leaves column triggers out" do
    result = export(include_board: false)

    assert_nil result.package.board
    assert_equal [ "schedule" ], result.package.section("triggers").pluck("kind")
    assert_equal "workflow", result.package.kind
  end

  test "a tracker trigger exports for any tracker of the installing project" do
    integration = create(:integration, :azure_devops, :active, company: @company, project: @source)
    tracker = create(:project_tracker, integration: integration)
    create(:trigger_binding, project: @source, workflow: @source.workflows.first, project_tracker: tracker,
                             event_type: "tracker.issue.status_changed", aixle_changes: "other_workflows", enabled: false)

    result = export

    entry = result.package.definition["triggers"].find { |t| t["kind"] == "tracker" }
    assert_equal [ "tracker.issue.status_changed", "other_workflows" ], [ entry["event_type"], entry["aixle_changes"] ]
    assert_match(/any tracker of the installing project/, result.notes.join)
  end

  test "a chat trigger exports its messenger as a requirement and installs listening to it" do
    create(:integration, provider: :teams, status: :active, company: @company, project: nil)
    create(:trigger_binding, project: @source, workflow: @source.workflows.first, event_type: "chat.message",
                             filter_predicate: { "provider" => "teams", "text" => { "op" => "starts_with", "value" => "deploy" } },
                             status_reporting: "lifecycle", enabled: false)

    result = export

    entry = result.package.definition["triggers"].find { |t| t["kind"] == "chat" }
    assert_equal [ "teams", "lifecycle" ], entry.values_at("chat_provider", "status_reporting")
    assert_equal({ "text" => { "op" => "starts_with", "value" => "deploy" } }, entry["filter_predicate"])
    assert_includes result.package.definition.dig("requires", "integrations"), "teams"
    copy = install(result.package).project
    installed = TriggerBinding.find_by!(project: copy, event_type: "chat.message")
    assert_equal [ "teams", "lifecycle" ], [ installed.chat_provider, installed.status_reporting ]
  end

  test "a chat trigger's channel stays with its company: not exported, and dropped from an older template" do
    create(:integration, provider: :teams, status: :active, company: @company, project: nil)
    create(:trigger_binding, project: @source, workflow: @source.workflows.first, enabled: false, chat_provider: "teams",
                             filter_predicate: { "text" => "deploy" })

    result = export

    entry = result.package.definition["triggers"].find { |t| t["kind"] == "chat" }
    assert_equal({ "text" => "deploy" }, entry["filter_predicate"])
    assert_match(/its channel is not exported; the installer connects one/, result.notes.join)

    entry["filter_predicate"] = { "channel" => "19:leaked@thread.tacv2", "conversation.type" => "direct", "text" => "deploy" }
    installed = TriggerBinding.find_by!(project: install(result.package).project, event_type: "chat.message")
    assert_equal [ { "text" => "deploy", "provider" => "teams" }, nil, false ],
                 [ installed.filter_predicate, installed.chat_conversation, installed.enabled ]
  end

  test "a workflow using a tracker tool exports a tracker requirement the installer can resolve" do
    tool = create(:tool, :system, name: "tracker_update_issue", requires_integration: Trackers::CAPABILITY)
    step = @source.workflows.sole.steps.order(:position).first
    step.update!(tool_ids: step.tool_ids + [ tool.id ])

    result = export

    assert_includes result.package.definition.dig("requires", "integrations"), Trackers::CAPABILITY
    item = install(result.package).install.setup_items.find_by!(ref: "integration:#{Trackers::CAPABILITY}")
    assert_equal "Connect a task tracker (Jira or Azure DevOps)", Templates::Presenter.setup_item(item)[:label]
  end
end

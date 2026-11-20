# frozen_string_literal: true

require "test_helper"

class Api::V1::Projects::Workflows::AggregatesTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @owner = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @owner)
    @workflow = create(:workflow, scope: @project, name: "Release")
    @build = create(:step, workflow: @workflow, name: "Build", position: 1)
    @test = create(:step, workflow: @workflow, name: "Test", position: 2, depends_on_step_ids: [ @build.id ])
    @lint = create(:sub_step, step: @build, name: "lint", position: 1)
    sign_in_as(@owner)
  end

  def save(steps, base_version: @workflow.reload.current_version_number, **workflow)
    put api_v1_project_workflow_aggregate_path(@project, @workflow),
        params: { base_version: base_version, aggregate: { name: "Release", **workflow, steps: steps } }, as: :json
  end

  test "one save rewrites the workflow and records exactly one version" do
    save([
      { id: @build.id, name: "Build", instructions: "make", sub_steps: [ { id: @lint.id, name: "lint" }, { name: "format" } ] },
      { key: "new-1", name: "Package", depends_on_step_ids: [ @build.id ] },
      { id: @test.id, name: "Test", depends_on_step_ids: [ "new-1" ] }
    ], description: "shipped")

    assert_response :success
    package = @workflow.steps.not_deleted.find_by!(name: "Package")
    assert_equal %w[Build Package Test], @workflow.steps.not_deleted.reorder(:position).pluck(:name)
    assert_equal [ package.id ], @test.reload.depends_on_step_ids
    assert_equal %w[lint format], @build.sub_steps.active.order(:position).pluck(:name)
    assert_equal "shipped", @workflow.reload.description
    assert_equal [ "created", "saved" ], @workflow.entity_versions.reorder(:number).map { |v| v.event.to_s }
    assert_equal 2, response.parsed_body["currentVersionNumber"]
  end

  test "dependencies are written on the saved steps without reloading each one by id" do
    assert_no_queries_match(/FROM "steps" WHERE "steps"\."id" = .* LIMIT /) do
      save([
        { id: @build.id, name: "Build" },
        { key: "new-1", name: "Package", depends_on_step_ids: [ @build.id ] },
        { id: @test.id, name: "Test", depends_on_step_ids: [ "new-1" ] }
      ])
    end

    assert_response :success
    package = @workflow.steps.not_deleted.find_by!(name: "Package")
    assert_equal [ @build.id ], package.depends_on_step_ids
    assert_equal [ package.id ], @test.reload.depends_on_step_ids
  end

  test "a step's reasoning effort is saved and read back" do
    save([ { id: @build.id, name: "Build", required_agent_runtime: "kiro_cli", preferred_model: "claude-opus-5.5",
             reasoning_effort: "high" },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ])

    assert_response :success
    assert_equal "high", @build.reload.reasoning_effort
    assert_equal "high", response.parsed_body["steps"].find { |s| s["id"] == @build.id }["reasoningEffort"]
  end

  test "a reasoning effort the step's runtime does not take is refused and nothing is written" do
    # The refusal comes from the first step's save, before the sub-steps the sync
    # preloads are read, which Bullet would report as an unused eager load.
    Bullet.enable = false
    save([ { id: @build.id, name: "Build", required_agent_runtime: "gemini_cli", preferred_model: "gemini-3-pro",
             reasoning_effort: "medium" },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ])

    assert_response :unprocessable_entity
    assert_match(/Reasoning effort medium is not available for gemini_cli/, response.parsed_body["error"])
    assert_nil @build.reload.required_agent_runtime
  ensure
    Bullet.enable = true
  end

  test "an approval step is saved with its kind and timeout settings" do
    save([ { id: @build.id, name: "Build" },
           { key: "new-1", name: "Sign off", kind: "approval", depends_on_step_ids: [ @build.id ],
             kind_config: { timeout_seconds: 3600, on_timeout: "skip" } } ])

    assert_response :success
    approval = @workflow.steps.not_deleted.find_by!(name: "Sign off")
    assert_equal "approval", approval.kind
    assert_equal({ "timeout_seconds" => 3600, "on_timeout" => "skip" }, approval.kind_config)
    saved = response.parsed_body["steps"].find { |s| s["id"] == approval.id }
    assert_equal "approval", saved["kind"]
    assert_equal({ "timeoutSeconds" => 3600, "onTimeout" => "skip" }, saved["kindConfig"])
  end

  test "steps left out are soft-deleted, not removed" do
    save([ { id: @build.id, name: "Build", sub_steps: [] } ])

    assert_response :success
    assert @test.reload.deleted?
    assert @lint.reload.deleted?
  end

  test "a save from a stale base version answers 409 and writes nothing" do
    Versions.save!(@workflow, actor: Versions::Actor.ui(@owner)) { @workflow.update!(description: "someone else") }

    save([ { id: @build.id, name: "Renamed" } ], base_version: 1)

    assert_response :conflict
    assert_equal "Build", @build.reload.name
    assert_not @test.reload.deleted?
  end

  test "a dependency on a step that is not in the payload is refused before anything is written" do
    save([ { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ])

    assert_response :unprocessable_entity
    assert_match(/depends on a step that is not in the workflow/, response.parsed_body["errors"].first)
    assert_not @build.reload.deleted?
  end

  test "a save that changes nothing records no version" do
    Versions.save!(@workflow, actor: Versions::Actor.ui(@owner)) { @workflow.update!(description: "d") }

    save([
      { id: @build.id, name: "Build", instructions: @build.instructions,
        sub_steps: [ { id: @lint.id, name: "lint", instructions: @lint.instructions, required: true } ] },
      { id: @test.id, name: "Test", instructions: @test.instructions, depends_on_step_ids: [ @build.id ] }
    ], description: "d")

    assert_response :success
    assert_equal false, response.parsed_body["versionCreated"] # rubocop:disable Minitest/RefuteFalse
  end

  test "an invalid step rolls the whole save back" do
    save([ { id: @build.id, name: "" }, { key: "x", name: "New" } ])

    assert_response :unprocessable_entity
    assert_equal "Build", @build.reload.name
    assert_nil @workflow.steps.find_by(name: "New")
  end

  test "the builder's camelCase payload is understood, draft keys and config included" do
    put api_v1_project_workflow_aggregate_path(@project, @workflow),
        params: {
          baseVersion: @workflow.reload.current_version_number,
          aggregate: {
            name: "Release", description: "",
            config: { base_tool_ids: [], inherit_all_project_resources: true },
            steps: [
              { id: @build.id, key: @build.id.to_s, name: "Build", allowNonInteractive: true,
                outputAssetSpecs: [ { name: "report", assetType: "file", required: true, namePattern: "*.md" } ],
                dependsOnStepIds: [], subSteps: [ { id: @lint.id, name: "lint", required: false } ] },
              { id: nil, key: "new-1", name: "Ship", dependsOnStepIds: [ @build.id.to_s ], subSteps: [] }
            ]
          }
        }, as: :json

    assert_response :success
    assert @build.reload.allow_non_interactive
    assert_equal [ { "name" => "report", "asset_type" => "file", "required" => true, "name_pattern" => "*.md" } ],
                 @build.output_asset_specs
    assert_not @lint.reload.required
    assert_equal [ @build.id ], @workflow.steps.not_deleted.find_by!(name: "Ship").depends_on_step_ids
    assert @workflow.reload.inherit_all_project_resources
    assert @test.reload.deleted?
  end

  test "a reference to a step created in the same save is stored with that step's id" do
    save([
      { id: @build.id, name: "Build", output_asset_specs: [ { name: "dist.md", required: true } ] },
      { key: "new-1", name: "Package", depends_on_step_ids: [ @build.id ] },
      { id: @test.id, name: "Test", depends_on_step_ids: [ "new-1" ],
        instructions: "Read {{output:#{@build.id}:dist.md}} after {{step:new-1}}." }
    ])

    assert_response :success
    package = @workflow.steps.not_deleted.find_by!(name: "Package")
    assert_equal "Read {{output:#{@build.id}:dist.md}} after {{step:#{package.id}}}.", @test.reload.instructions
    assert_empty response.parsed_body["issues"]
  end

  test "the save response and the check report what a run would trip on, without blocking the save" do
    steps = [
      { id: @build.id, name: "Build", instructions: "Read {{output:#{@test.id}:report.md}}." },
      { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ], output_asset_specs: [ { name: "report.md" } ] }
    ]

    before = @build.instructions

    post check_api_v1_project_workflow_aggregate_path(@project, @workflow),
         params: { aggregate: { name: "Release", steps: steps } }, as: :json

    assert_response :success
    issue = response.parsed_body["issues"].sole
    assert_equal [ "output_not_upstream", @build.id.to_s, "error" ], issue.values_at("code", "stepKey", "severity")
    assert_equal before, @build.reload.instructions, "a check writes nothing"

    save(steps)

    assert_response :success
    assert_equal [ "output_not_upstream" ], response.parsed_body["issues"].pluck("code")
    assert_equal "Read {{output:#{@test.id}:report.md}}.", @build.reload.instructions
  end

  test "a send action saves only when an approval step runs right before it" do
    server = create(:mcp_server, :with_tool_schemas, scope: @project, snapshot_tools: [ { "name" => "send_invoice" } ])
    action = { key: "new-2", name: "Send", kind: "action",
               kind_config: { target: "mcp_tool", mcp_server_id: server.id, tool: "send_invoice",
                              arguments: { to: "{{context:customer.email}}" }, effect: "send" } }
    gate = { key: "new-1", name: "Sign off", kind: "approval", kind_config: { timeout_seconds: 3600 } }

    with_feature(:workflow_action_steps, true, company: @company) do
      save([ { id: @build.id, name: "Build" }, gate, action.merge(depends_on_step_ids: [ @build.id ]) ])

      assert_response :unprocessable_entity
      assert_equal [ "A send action must run after an approval step that stops the run when no one approves." ],
                   response.parsed_body["errors"]
      assert_equal %w[Build Test], @workflow.steps.not_deleted.reorder(:position).pluck(:name), "nothing was written"

      save([ { id: @build.id, name: "Build" }, gate, action.merge(depends_on_step_ids: [ "new-1" ]) ])

      assert_response :success
      sent = @workflow.steps.not_deleted.find_by!(name: "Send")
      assert_equal({ "to" => "{{context:customer.email}}" }, sent.kind_config["arguments"])
      assert_equal "approval", Step.find(sent.depends_on_step_ids.sole).kind
    end
  end

  test "detaching a block saves a plain action on the same operation that still passes step validation" do
    Bullet.enable = false
    connector = create(:api_connector, scope: @project, name: "billing")
    operation = create(:api_operation, api_connector: connector, name: "list_invoices", effect: "read")
    manifest = Modules::BlockBuilder.from_operation(project: @project, operation: operation, label: "List invoices").manifest
    create(:module_definition, kind: "block", scope: @project, namespace: manifest["namespace"], slug: manifest["slug"], version: 1, manifest: manifest)
    ref = "#{manifest['namespace']}/#{manifest['slug']}@1"
    attached = { key: "new-1", name: "List", kind: "action", output_asset_specs: [ { name: "result.json" } ],
                 kind_config: { target: "rest_operation", api_operation_id: operation.id, effect: "read", arguments: {},
                                output_name: "result.json", block: ref } }

    with_feature(:workflow_action_steps, true, company: @company) do
      save([ { id: @build.id, name: "Build" }, attached ])
      assert_response :success
      step = @workflow.steps.not_deleted.find_by!(name: "List")
      assert_equal ref, step.kind_config["block"]

      detached = attached.merge(id: step.id, kind_config: attached[:kind_config].except(:block))
      save([ { id: @build.id, name: "Build" }, detached.except(:key) ])

      assert_response :success
      step.reload
      assert_not step.kind_config.key?("block")
      assert_equal operation.id, step.kind_config["api_operation_id"]
      assert step.valid?, step.errors.full_messages.to_sentence
      assert_not response.parsed_body["steps"].find { |served| served["name"] == "List" }["kindConfig"].key?("block")
    end
  ensure
    Bullet.enable = true
  end

  test "a tool's argument names are saved and read back exactly, nested ones too" do
    schema = { "type" => "object", "properties" => {
      "pageSize" => { "type" => "integer" }, "filter" => { "type" => "object" }
    } }
    server = create(:mcp_server, :with_tool_schemas, scope: @project,
                                 snapshot_tools: [ { "name" => "list", "input_schema" => schema, "annotations" => { "readOnlyHint" => true } } ])
    arguments = { "pageSize" => 5, "filter" => { "teamId" => "x" } }

    with_feature(:workflow_action_steps, true, company: @company) do
      save([ { id: @build.id, name: "Build" },
             { key: "new-1", name: "List", kind: "action", output_asset_specs: [ { name: "result.json" } ],
               kind_config: { target: "mcp_tool", mcpServerId: server.id, tool: "list", effect: "read",
                              arguments: arguments, outputName: "result.json" } } ])
    end

    assert_response :success
    assert_equal arguments, @workflow.steps.not_deleted.find_by!(name: "List").kind_config["arguments"]
    served = response.parsed_body["steps"].find { |step| step["name"] == "List" }
    assert_equal arguments, served["kindConfig"]["arguments"]
    assert_equal "mcp_tool", served["kindConfig"]["target"]
    assert_equal server.id, served["kindConfig"]["mcpServerId"]
  end

  def positions_payload(build_pos, test_pos)
    [ { id: @build.id, name: "Build", **build_pos }, { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ], **test_pos } ]
  end

  test "canvas positions are saved for existing and draft steps and read back" do
    save([ { id: @build.id, name: "Build", canvas_position: { x: 10.4, y: 20 } },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] },
           { key: "new-1", name: "Package", canvas_position: { x: -5, y: 7 } } ])

    assert_response :success
    assert_equal({ "x" => 10, "y" => 20 }, @build.reload.canvas_position)
    assert_nil @test.reload.canvas_position
    assert_equal({ "x" => -5, "y" => 7 }, @workflow.steps.find_by!(name: "Package").canvas_position)
    assert_equal({ "x" => 10, "y" => 20 }, response.parsed_body["steps"].find { |s| s["id"] == @build.id }["canvasPosition"])
  end

  test "a step sent without a canvas position keeps its stored one" do
    @build.update!(canvas_position: { x: 1, y: 2 })

    save(positions_payload({ instructions: "changed" }, {}))

    assert_response :success
    assert_equal({ "x" => 1, "y" => 2 }, @build.reload.canvas_position)
  end

  test "a null canvas position clears the stored one" do
    @build.update!(canvas_position: { x: 1, y: 2 })

    save(positions_payload({ canvas_position: nil }, {}))

    assert_response :success
    assert_nil @build.reload.canvas_position
  end

  test "a layout-only change records a version" do
    Versions.save!(@workflow, actor: Versions::Actor.ui(@owner)) { @workflow.update!(description: "d") }
    before = @workflow.reload.current_version_number

    save(positions_payload({ canvas_position: { x: 40, y: 50 } }, {}), description: "d")

    assert_response :success
    assert response.parsed_body["versionCreated"]
    assert_equal before + 1, @workflow.reload.current_version_number
  end

  test "a malformed steps element does not shift a null position onto the next step" do
    @build.update!(canvas_position: { x: 1, y: 2 })
    @test.update!(canvas_position: { x: 7, y: 8 })

    save([ "junk", { id: @build.id, name: "Build", canvas_position: nil },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ], canvas_position: { x: 9, y: 9 } } ])

    assert_response :success
    assert_nil @build.reload.canvas_position
    assert_equal({ "x" => 9, "y" => 9 }, @test.reload.canvas_position)
  end

  test "an invalid canvas position answers 422 and writes nothing" do
    save(positions_payload({ canvas_position: { x: 200_000, y: 0 } }, { instructions: "never" }))

    assert_response :unprocessable_entity
    assert_match(/Canvas position must be \{x, y\} numbers/, response.parsed_body["error"])
    assert_nil @build.reload.canvas_position
    assert_not_equal "never", @test.reload.instructions
  end

  test "budget caps are saved for the workflow and its steps and read back" do
    save([ { id: @build.id, name: "Build", budget_cents: 300 },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] },
           { key: "new-1", name: "Package", budget_cents: 45 } ], budget_cents: 1000)

    assert_response :success
    assert_equal 1000, @workflow.reload.budget_cents
    assert_equal 300, @build.reload.budget_cents
    assert_nil @test.reload.budget_cents
    assert_equal 45, @workflow.steps.find_by!(name: "Package").budget_cents
    assert_equal 1000, response.parsed_body.dig("workflow", "budgetCents")
    assert_equal 300, response.parsed_body["steps"].find { |s| s["id"] == @build.id }["budgetCents"]
  end

  test "a workflow and steps sent without budget caps keep the stored ones" do
    @workflow.update!(budget_cents: 1000)
    @build.update!(budget_cents: 300)

    save([ { id: @build.id, name: "Build", instructions: "changed" },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ])

    assert_response :success
    assert_equal [ 1000, 300 ], [ @workflow.reload.budget_cents, @build.reload.budget_cents ]
  end

  test "a null budget cap clears the stored one on the workflow and on a step" do
    @workflow.update!(budget_cents: 1000)
    @build.update!(budget_cents: 300)
    @test.update!(budget_cents: 20)

    save([ "junk", { id: @build.id, name: "Build", budget_cents: nil },
           { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ], budget_cents: nil)

    assert_response :success
    assert_nil @workflow.reload.budget_cents
    assert_nil @build.reload.budget_cents
    assert_equal 20, @test.reload.budget_cents
  end

  test "an out-of-range budget cap answers 422 and writes nothing" do
    save([ { id: @build.id, name: "Build", budget_cents: 0 }, { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ])
    assert_response :unprocessable_entity
    assert_nil @build.reload.budget_cents

    save([ { id: @build.id, name: "Build" } ], budget_cents: Budgets::MAX_CENTS + 1)
    assert_response :unprocessable_entity
    assert_nil @workflow.reload.budget_cents
  end

  test "a malformed budget cap answers 422 and keeps the stored caps" do
    @workflow.update!(budget_cents: 1000)
    @build.update!(budget_cents: 300)
    steps = ->(cap) { [ { id: @build.id, name: "Build", budget_cents: cap }, { id: @test.id, name: "Test", depends_on_step_ids: [ @build.id ] } ] }

    [ "", false, "abc", [ 5 ], { "a" => 1 }, 1.5 ].each do |bad|
      save(steps.call(nil), budget_cents: bad)
      assert_response :unprocessable_entity, "workflow #{bad.inspect}"
      save(steps.call(bad))
      assert_response :unprocessable_entity, "step #{bad.inspect}"
    end
    assert_equal [ 1000, 300 ], [ @workflow.reload.budget_cents, @build.reload.budget_cents ]
  end

  test "a non-finite JSON number is refused, not read as no cap" do
    @workflow.update!(budget_cents: 1000)
    @build.update!(budget_cents: 300)
    body = %({"base_version":#{@workflow.current_version_number},"aggregate":{"name":"Release","budget_cents":1e400,) +
           %("steps":[{"id":#{@build.id},"name":"Build","budget_cents":1e400}]}})

    put api_v1_project_workflow_aggregate_path(@project, @workflow), params: body,
                                                                     headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :unprocessable_entity
    assert_equal [ 1000, 300 ], [ @workflow.reload.budget_cents, @build.reload.budget_cents ]
  end
end

# frozen_string_literal: true

require "test_helper"

class Versions::WorkflowSnapshotTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, company: @company)
    @project = create(:project, company: @company, owner: @user)
    @actor = Versions::Actor.ui(@user)
    @workflow = create(:workflow, scope: @project, name: "Release")
    @build = create(:step, workflow: @workflow, name: "Build", position: 1, instructions: "build it")
    @test = create(:step, workflow: @workflow, name: "Test", position: 2, depends_on_step_ids: [ @build.id ])
    @check = create(:sub_step, step: @build, name: "lint", position: 1)
  end

  test "the snapshot holds live steps with their live sub-steps, in order" do
    create(:step, workflow: @workflow, name: "Gone", position: 3).soft_delete!

    snapshot = Versions::Snapshot.dump(@workflow)

    assert_equal %w[Build Test], snapshot["steps"].pluck("name")
    assert_equal [ @build.id ], snapshot["steps"].second["depends_on_step_ids"]
    assert_equal [ { "id" => @check.id, "name" => "lint", "instructions" => @check.instructions, "position" => 1, "required" => true } ],
                 snapshot["steps"].first["sub_steps"]
  end

  test "the snapshot names only the resources that still exist" do
    kept, deleted = create_list(:repository, 2, scope: @project)
    @workflow.merge_config!("base_repository_ids" => [ deleted.id, kept.id ])
    @build.update!(repository_ids: [ deleted.id, kept.id ])

    deleted.destroy!
    snapshot = Versions::Snapshot.dump(@workflow.reload)

    assert_equal [ kept.id ], snapshot["config"]["base_repository_ids"]
    assert_equal [ kept.id ], snapshot["steps"].first["repository_ids"]
  end

  test "revert brings back deleted steps and sub-steps by id and retires steps added since" do
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "v1") }
    v1 = @workflow.latest_version

    Versions.save!(@workflow, actor: @actor) do
      @test.destroy
      @check.destroy
      @build.update!(instructions: "build it differently")
      create(:step, workflow: @workflow, name: "Deploy", position: 3)
      Positions.reorder!(@workflow.steps, [ @workflow.steps.not_deleted.find_by(name: "Deploy").id, @build.id ])
    end

    Versions.revert!(@workflow, to: v1, actor: @actor)

    live = @workflow.steps.not_deleted.reorder(:position).to_a
    assert_equal [ [ @build.id, "Build" ], [ @test.id, "Test" ] ], live.map { |s| [ s.id, s.name ] }
    assert_equal "build it", live.first.instructions
    assert_equal [ @build.id ], live.second.depends_on_step_ids
    assert_equal [ @check.id ], @build.reload.sub_steps.active.pluck(:id)
    assert @workflow.steps.find_by(name: "Deploy").deleted?
    assert_equal v1.snapshot["steps"], @workflow.reload.latest_version.snapshot["steps"]
  end

  test "a step's reasoning effort is part of its snapshot and comes back on revert" do
    Versions.save!(@workflow, actor: @actor) do
      @build.update!(required_agent_runtime: "kiro_cli", preferred_model: "claude-opus-5.5", reasoning_effort: "high")
    end
    v1 = @workflow.latest_version
    assert_equal "high", v1.snapshot["steps"].first["reasoning_effort"]

    Versions.save!(@workflow, actor: @actor) { @build.update!(reasoning_effort: nil) }
    assert_nil @workflow.latest_version.snapshot["steps"].first["reasoning_effort"]

    Versions.revert!(@workflow, to: v1, actor: @actor)

    assert_equal "high", @build.reload.reasoning_effort
  end

  test "a snapshot keeps a step's kind and kind_config" do
    config = { "timeout_seconds" => 3600, "on_timeout" => "skip" }
    gate = nil
    Versions.save!(@workflow, actor: @actor) do
      gate = @workflow.steps.create!(name: "Gate", position: 3, kind: "approval", kind_config: config)
    end
    v1 = @workflow.latest_version
    entry = v1.snapshot["steps"].find { |s| s["id"] == gate.id }
    assert_equal "approval", entry["kind"]
    assert_equal config, entry["kind_config"]

    Versions.save!(@workflow, actor: @actor) { gate.update!(kind: "wait", kind_config: { "delay_seconds" => 60 }) }
    Versions.revert!(@workflow, to: v1, actor: @actor)

    assert_equal "approval", gate.reload.kind
    assert_equal config, gate.kind_config
  end

  test "reverting brings a send action back with its approval, and refuses a version that has none" do
    server = create(:mcp_server, :with_tool_schemas, scope: @project, snapshot_tools: [ { "name" => "send_invoice" } ])
    config = { "target" => "mcp_tool", "mcp_server_id" => server.id, "tool" => "send_invoice", "effect" => "send" }
    with_feature(:workflow_action_steps, true, company: @company) do
      action = nil
      Versions.save!(@workflow, actor: @actor) do
        gate = @workflow.steps.create!(name: "Gate", position: 3, kind: "approval", kind_config: { "timeout_seconds" => 3600 })
        action = @workflow.steps.create!(name: "Send", position: 4, kind: "action", kind_config: config,
                                         depends_on_step_ids: [ gate.id ])
      end
      v1 = @workflow.latest_version
      Versions.save!(@workflow, actor: @actor) do
        action.update!(depends_on_step_ids: [], kind_config: config.merge("effect" => "write"))
      end

      Versions.revert!(@workflow, to: v1, actor: @actor)

      assert_equal "send", action.reload.kind_config["effect"]
      assert_equal [ "approval" ], Step.where(id: action.depends_on_step_ids).map(&:kind)

      tampered = v1.snapshot.merge("steps" => v1.snapshot["steps"].map { |s| s["id"] == action.id ? s.merge("depends_on_step_ids" => []) : s })
      EntityVersion.where(id: v1.id).update_all(snapshot: tampered)
      v1.reload

      error = assert_raises(ActiveRecord::RecordInvalid) { Versions.revert!(@workflow, to: v1, actor: @actor) }
      assert_includes error.record.errors[:base], "A send action must run after an approval step that stops the run when no one approves."
    end
  end

  # A key a snapshot lacks is a column added after that version was saved, so the
  # revert gives it the column's default rather than keeping the row's current value.
  test "reverting to a snapshot without a column restores that column's default" do
    Versions.save!(@workflow, actor: @actor) { @build.update!(required_agent_runtime: "gemini_cli") }
    v1 = @workflow.latest_version
    legacy = v1.snapshot.except("description").merge(
      "steps" => v1.snapshot["steps"].map do |step|
        step.except("reasoning_effort", "on_failure", "max_retries")
            .merge("sub_steps" => step["sub_steps"].map { |sub| sub.except("required") })
      end
    )
    EntityVersion.where(id: v1.id).update_all(snapshot: legacy)
    v1.reload

    Versions.save!(@workflow, actor: @actor) do
      @workflow.update!(description: "later")
      @build.update!(required_agent_runtime: "kiro_cli", preferred_model: "claude-opus-5.5", reasoning_effort: "xhigh",
                     on_failure: "skip", max_retries: 3)
      @check.update!(required: false)
    end

    Versions.revert!(@workflow, to: v1, actor: @actor)

    @build.reload
    assert_nil @workflow.reload.description
    assert_equal "gemini_cli", @build.required_agent_runtime
    assert_nil @build.preferred_model
    assert_nil @build.reasoning_effort, "a nullable column with no default comes back nil"
    assert_equal "fail", @build.on_failure, "a NOT NULL column comes back as its default"
    assert_equal 0, @build.max_retries
    assert @check.reload.required, "a sub-step column comes back as its default"
  end

  test "reverting to a snapshot without a resource list empties that list" do
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "bare") }
    bare = @workflow.latest_version
    legacy = bare.snapshot.merge("config" => bare.snapshot["config"].except("base_repository_ids"),
                                 "steps" => bare.snapshot["steps"].map { |step| step.except("config_item_ids") })
    EntityVersion.where(id: bare.id).update_all(snapshot: legacy)

    Versions.save!(@workflow, actor: @actor) do
      @workflow.merge_config!("base_repository_ids" => [ create(:repository, scope: @project).id ])
      @build.update!(config_item_ids: [ create(:config_item, scope: @project).id ])
    end

    Versions.revert!(@workflow, to: bare.reload, actor: @actor)

    assert_empty @workflow.reload.base_repository_ids
    assert_empty @build.reload.config_item_ids
  end

  test "revert restores a dependency chain whatever order the steps were saved in" do
    deploy = create(:step, workflow: @workflow, name: "Deploy", position: 3, depends_on_step_ids: [ @test.id ])
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "chain") }
    chain = @workflow.latest_version

    Versions.save!(@workflow, actor: @actor) do
      deploy.update!(depends_on_step_ids: [])
      @test.update!(depends_on_step_ids: [ deploy.id ])
    end

    Versions.revert!(@workflow, to: chain, actor: @actor)

    assert_equal [ @test.id ], deploy.reload.depends_on_step_ids
    assert_equal [ @build.id ], @test.reload.depends_on_step_ids
  end

  test "revert drops references to rows that no longer exist and keeps archived ones" do
    gone = create(:tool, scope: @project)
    archived = create(:tool, scope: @project)
    @build.update!(tool_ids: [ gone.id, archived.id ])
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "with tools") }
    with_tools = @workflow.latest_version

    Versions.save!(@workflow, actor: @actor) { @build.update!(tool_ids: []) }
    gone.tool_results.delete_all
    gone.delete
    archived.soft_delete!

    Versions.revert!(@workflow, to: with_tools, actor: @actor)

    assert_equal [ archived.id ], @build.reload.tool_ids
  end

  # == runner (DESIGN.md §2.4, §3.4) ==

  test "the runner is in the snapshot, and a hosted workflow's snapshot is as it was before runners" do
    runner = create(:runner, company: @company, created_by: @user)

    assert_not Versions::Snapshot.dump(@workflow).key?("runner_id")

    @workflow.update!(runner: runner)
    assert_equal runner.id, Versions::Snapshot.dump(@workflow)["runner_id"]
  end

  test "saving an unchanged hosted workflow over a snapshot from before runners records nothing" do
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "v1") }

    assert_no_difference -> { @workflow.entity_versions.count } do
      Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "v1") }
    end
  end

  test "revert restores the runner, one deleted since included, and hosted for a version that had none" do
    runner = create(:runner, company: @company, created_by: @user)
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "hosted") }
    hosted = @workflow.latest_version
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(runner: runner) }
    on_runner = @workflow.latest_version
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(runner: nil) }
    runner.soft_delete!

    Versions.revert!(@workflow, to: on_runner, actor: @actor)
    assert_equal runner.id, @workflow.reload.runner_id

    Versions.revert!(@workflow, to: hosted, actor: @actor)
    assert_nil @workflow.reload.runner_id
  end

  test "a version restored onto a disabled or revoked runner keeps it" do
    runner = create(:runner, company: @company, created_by: @user)
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(runner: runner) }
    on_runner = @workflow.latest_version
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(runner: nil) }
    runner.revoke!

    Versions.revert!(@workflow, to: on_runner, actor: @actor)

    assert_equal runner.id, @workflow.reload.runner_id
  end

  test "a version whose runner row is gone restores Hosted" do
    runner = create(:runner, company: @company, created_by: @user)
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(runner: runner, description: "on runner") }
    on_runner = @workflow.latest_version
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(runner: nil, description: "hosted") }
    runner.delete

    Versions.revert!(@workflow, to: on_runner, actor: @actor)

    assert_equal [ nil, "on runner" ], [ @workflow.reload.runner_id, @workflow.description ]
  end

  test "a version naming a runner the project can no longer use restores Hosted" do
    other_project = create(:project, company: @company, owner: @user)
    foreign = create(:runner, company: @company, project: other_project, created_by: @user)
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "stale") }
    stale = @workflow.latest_version
    EntityVersion.where(id: stale.id).update_all(snapshot: stale.snapshot.merge("runner_id" => foreign.id))
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "now") }

    Versions.revert!(@workflow, to: stale.reload, actor: @actor)

    assert_equal [ nil, "stale" ], [ @workflow.reload.runner_id, @workflow.description ]
  end

  test "a canvas position is in the snapshot and comes back on revert; an unplaced step adds no key" do
    assert_not Versions::Snapshot.dump(@workflow)["steps"].first.key?("canvas_position")

    Versions.save!(@workflow, actor: @actor) { @build.update!(canvas_position: { x: 5, y: 6 }) }
    v1 = @workflow.latest_version
    assert_equal({ "x" => 5, "y" => 6 }, v1.snapshot["steps"].first["canvas_position"])

    Versions.save!(@workflow, actor: @actor) { @build.update!(canvas_position: { x: 90, y: 91 }) }
    Versions.revert!(@workflow, to: v1, actor: @actor)

    assert_equal({ "x" => 5, "y" => 6 }, @build.reload.canvas_position)
  end

  test "reverting to a snapshot from before canvas positions clears them" do
    Versions.save!(@workflow, actor: @actor) { @workflow.update!(description: "v1") }
    v1 = @workflow.latest_version
    assert_not v1.snapshot["steps"].any? { |s| s.key?("canvas_position") }

    Versions.save!(@workflow, actor: @actor) { @build.update!(canvas_position: { x: 90, y: 91 }) }
    Versions.revert!(@workflow, to: v1, actor: @actor)

    assert_nil @build.reload.canvas_position
  end
end

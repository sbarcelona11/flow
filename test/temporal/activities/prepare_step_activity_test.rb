# frozen_string_literal: true

require "test_helper"

module Activities
  module Workflow
    class PrepareStepActivityTest < ActiveSupport::TestCase
      setup do
        @company = create(:company)
        @user = create(:user, company: @company)
        @project = create(:project, company: @company, owner: @user)
        @workflow = create(:workflow, scope: @project)
        @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)

        Rails.logger.stubs(:info)
        Rails.logger.stubs(:warn)
        Rails.logger.stubs(:error)
      end

      test "refuses a step that has reached its cap, without building a session" do
        step = create(:step, workflow: @workflow)
        step_run = create(:step_run, workflow_run: @run, step: step)
        step_run.update_columns(budget_cents: 100)
        spend(step_run, 102)
        ::Trackers::IssueFileCopy.expects(:new).never

        result = nil
        assert_no_difference -> { TerminalSession.count } do
          result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })
        end

        assert result["failed"]
        assert_equal %w[failed step_id step_run_id validation_errors workflow_run_id], result.keys.sort
        step_run.reload
        assert_equal "failed", step_run.state
        assert_equal "budget_exceeded", step_run.error_category
        assert_equal "Budget exceeded: this step has spent $1.02 of its $1.00 cap, so it was not started again.",
                     step_run.error_message
        assert_nil @run.reload.failure_reason
      end

      test "refuses a retry attempt of a capped step on the spend of the earlier attempt" do
        step = create(:step, workflow: @workflow)
        first = create(:step_run, workflow_run: @run, step: step)
        first.update_columns(budget_cents: 100)
        spend(first, 100)
        retry_run = StepRun.next_attempt!(workflow_run: @run, step: step)
        retry_run.update_columns(budget_cents: 100)

        result = nil
        assert_no_difference -> { TerminalSession.count } do
          result = run_activity(PrepareStepActivity, { "step_run_id" => retry_run.id })
        end

        assert result["failed"]
        assert_equal "budget_exceeded", retry_run.reload.error_category
        assert_equal "failed", retry_run.state
      end

      test "refuses any step once the run cap is reached, and records why the run is failing" do
        spender = create(:step, workflow: @workflow, name: "Spender")
        spender_run = create(:step_run, workflow_run: @run, step: spender)
        spend(spender_run, 510)
        @run.update_columns(budget_cents: 500)
        step_run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow, name: "Next"))

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert result["failed"]
        step_run.reload
        assert_equal "budget_exceeded", step_run.error_category
        assert_equal "Budget exceeded: this run has spent $5.10 of its $5.00 cap, so it was not started again.",
                     step_run.error_message
        assert_equal "budget_exceeded", @run.reload.failure_reason
      end

      test "a run cap does not replace a failure reason the run already has" do
        spender_run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow, name: "Spender"))
        spend(spender_run, 510)
        @run.update_columns(budget_cents: 500, failure_reason: "quota_exceeded")
        step_run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow, name: "Next"))

        run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert_equal "quota_exceeded", @run.reload.failure_reason
      end

      test "the budget refusal comes before the reference and input checks" do
        step = create(:step, workflow: @workflow, input_asset_specs: [ { "name" => "nowhere.md", "required" => true } ])
        step_run = create(:step_run, workflow_run: @run, step: step)
        step_run.update_columns(budget_cents: 100)
        spend(step_run, 100)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert result["failed"]
        assert_equal "budget_exceeded", step_run.reload.error_category
      end

      test "a capped step with room left starts as before" do
        step = create(:step, workflow: @workflow)
        step_run = create(:step_run, workflow_run: @run, step: step)
        step_run.update_columns(budget_cents: 100)
        spend(step_run, 99)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"]
        assert_equal "running", step_run.reload.state
        assert_nil step_run.error_category
      end

      test "other failures carry no error category" do
        step = create(:step, workflow: @workflow, input_asset_specs: [ { "name" => "nowhere.md", "required" => true } ])
        step_run = create(:step_run, workflow_run: @run, step: step)

        run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert_nil step_run.reload.error_category
      end

      test "a step asset satisfies a required input_asset_spec" do
        asset = create(:asset, scope: @project, created_by: @user, name: "brief.md")
        step = create(:step, workflow: @workflow,
          input_asset_specs: [ { "name" => "brief.md", "required" => true } ],
          asset_ids: [ asset.id ])
        step_run = create(:step_run, workflow_run: @run, step: step)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"]
        assert_equal "running", step_run.reload.state
      end

      test "a workflow base asset satisfies a required input_asset_spec" do
        asset = create(:asset, scope: @project, created_by: @user, name: "style_guide.md")
        @workflow.merge_config!(base_asset_ids: [ asset.id ])
        step = create(:step, workflow: @workflow,
          input_asset_specs: [ { "name" => "style_guide.md", "required" => true } ])
        step_run = create(:step_run, workflow_run: @run, step: step)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"]
      end

      test "a missing required input_asset_spec fails validation" do
        step = create(:step, workflow: @workflow,
          input_asset_specs: [ { "name" => "nowhere.md", "required" => true } ])
        step_run = create(:step_run, workflow_run: @run, step: step)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert result["failed"]
        assert_includes result["validation_errors"].join, "nowhere.md"
        assert_equal "failed", step_run.reload.state
      end

      test "a spec entry that is not a spec is ignored instead of failing the step" do
        step = create(:step, workflow: @workflow)
        step.update_column(:input_asset_specs, [ 42 ])
        step_run = create(:step_run, workflow_run: @run, step: step)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"]
      end

      test "a validator that crashes does not start the step" do
        step = create(:step, workflow: @workflow, input_asset_specs: [ { "name" => "brief.md" } ])
        step_run = create(:step_run, workflow_run: @run, step: step)
        InputValidator.stubs(:new).raises(StandardError, "boom")

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert result["failed"]
        assert_match(/input validation could not run: boom/, result["validation_errors"].join)
        assert_equal "failed", step_run.reload.state
      end

      test "outputs of a step two links up satisfy a required input" do
        collect = create(:step, workflow: @workflow, name: "Collect")
        analyze = create(:step, workflow: @workflow, name: "Analyze", depends_on_step_ids: [ collect.id ])
        report = create(:step, workflow: @workflow, name: "Report", depends_on_step_ids: [ analyze.id ],
          input_asset_specs: [ { "name" => "summary.md", "required" => true } ])
        collect_run = create(:step_run, workflow_run: @run, step: collect)
        create(:workflow_run_asset, workflow_run: @run, produced_by_step_run: collect_run, name: "summary.md")
        step_run = create(:step_run, workflow_run: @run, step: report)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"], result["validation_errors"].inspect
      end

      test "a container path in an input spec name matches the file it names" do
        asset = create(:asset, scope: @project, created_by: @user, name: "brief.md", folder: "docs")
        step = create(:step, workflow: @workflow, asset_ids: [ asset.id ])
        step.update_column(:input_asset_specs, [ { "name" => "/workspace/assets/docs/brief.md" } ])
        step_run = create(:step_run, workflow_run: @run, step: step)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"], result["validation_errors"].inspect
      end

      test "a reference to an asset the step does not get fails the step before its session starts" do
        asset = create(:asset, scope: @project, created_by: @user, name: "brief.md")
        step = create(:step, workflow: @workflow, instructions: "Read {{asset:#{asset.id}}}.")
        step_run = create(:step_run, workflow_run: @run, step: step)

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        assert result["failed"]
        assert_match(/Reference check failed: .*brief\.md, which is not attached/, step_run.reload.error_message)
      end

      test "a step waits for the issue's files a tracker trigger is copying, and its session is told where they are" do
        Settings.trackers.stubs(:copy_wait_seconds).returns(30)
        Settings.trackers.stubs(:copy_poll_seconds).returns(0.05)
        step_run, session = copying_run
        @youtrack.add_file(FakeYoutrack::Api::ISSUE_1, name: "log.txt", bytes: "boom")
        copier = Thread.new do
          sleep 0.2
          ::Trackers::CopyAttachmentsJob.perform_now(@run.id)
        end

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"]
        assert_not copier.alive?, "the step started before the copy finished"
        content = ContextBuilders::TrackerContext.new(session).build.sole.content
        assert_match "Already in your workspace: `/workspace/tracker/APP-1/log.txt`", content
        assert_no_match "had not finished", content
      ensure
        copier&.join
      end

      test "a step stops waiting for a copy that outlasts the bound, and its session is told the copy had not finished" do
        Settings.trackers.stubs(:copy_wait_seconds).returns(0)
        step_run, session = copying_run

        result = run_activity(PrepareStepActivity, { "step_run_id" => step_run.id })

        refute result["failed"]
        assert_equal "running", step_run.reload.state
        assert_match "had not finished when this step started: `tracker_download_attachments` fetches the rest",
                     ContextBuilders::TrackerContext.new(session).build.sole.content
      end

      private

      def spend(step_run, cents)
        session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step",
                                            state: "finished", started_at: 1.hour.ago)
        UsageStatistic.create!(terminal_session: session, cost_cents: cents)
        step_run.update_columns(terminal_session_id: session.id)
      end

      # A run a tracker trigger with copy_attachments started, whose copy is still pending.
      def copying_run
        @youtrack = stub_youtrack!
        integration = create(:integration, :youtrack, :active, company: @company, project: @project)
        ::Trackers::Provisioning.ensure_for!(integration)
        tracker = ProjectTracker.find_by!(project: @project, external_scope_id: FakeYoutrack::Api::APP)
        board = create(:board, project: @project)
        task = create(:board_task, board: board, board_column: create(:board_column, board: board))
        @run.update!(board_task: task, shared_context: { "tracker" => {
          "project_tracker_id" => tracker.id, "handle" => tracker.handle, "event_type" => "tracker.issue.status_changed",
          "issue" => { "id" => FakeYoutrack::Api::ISSUE_1, "key" => "APP-1" }
        } })
        ::Trackers::IssueFileCopy.pending!(@run.id)
        step_run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))
        [ step_run, create(:terminal_session, :agent_session, user: @user, project: @project, step_run: step_run) ]
      end
    end
  end
end

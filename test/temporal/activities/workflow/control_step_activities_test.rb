# frozen_string_literal: true

require "test_helper"

module Activities
  module Workflow
    class ControlStepActivitiesTest < ActiveSupport::TestCase
      setup do
        @company = create(:company)
        @user = create(:user, company: @company)
        @project = create(:project, company: @company, owner: @user)
        @workflow = create(:workflow, scope: @project)
        @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
        approval = create(:step, workflow: @workflow, position: 1, kind: "approval", agent: nil,
                                 kind_config: { "timeout_seconds" => 3600 })
        wait = create(:step, workflow: @workflow, position: 2, kind: "wait", agent: nil,
                             kind_config: { "until_context_key" => "campaign.publish_at" })
        @approval_run = create(:step_run, workflow_run: @run, step: approval)
        @wait_run = create(:step_run, workflow_run: @run, step: wait)

        Rails.logger.stubs(:info)
        Rails.logger.stubs(:warn)
        Rails.logger.stubs(:error)
      end

      test "opening an approval parks the step run and returns its timeout" do
        result = OpenApprovalActivity.new.execute("step_run_id" => @approval_run.id)

        assert_equal({ "timeout_seconds" => 3600, "on_timeout" => "fail" }, result)
        assert_equal "waiting_input", @approval_run.reload.state
        assert @approval_run.started_at
      end

      test "opening an approval again keeps the first started_at" do
        OpenApprovalActivity.new.execute("step_run_id" => @approval_run.id)
        first = @approval_run.reload.started_at

        travel 5.minutes do
          OpenApprovalActivity.new.execute("step_run_id" => @approval_run.id)
        end

        assert_equal first, @approval_run.reload.started_at
      end

      test "an expired approval with on_timeout fail fails with approval_timeout" do
        @approval_run.mark_awaiting_approval!

        result = ExpireApprovalActivity.new.execute("step_run_id" => @approval_run.id)

        assert_equal "failed", result["outcome"]
        assert_equal "approval_timeout", @approval_run.reload.error_category
        assert_equal "No one approved within 1 h", @approval_run.error_message
      end

      test "an expired approval with on_timeout skip skips the step run" do
        @approval_run.step.update!(kind_config: { "timeout_seconds" => 1800, "on_timeout" => "skip" })
        @approval_run.mark_awaiting_approval!

        result = ExpireApprovalActivity.new.execute("step_run_id" => @approval_run.id)

        assert_equal "skipped", result["outcome"]
        assert_equal "No one approved within 30 min", @approval_run.reload.skip_reason
      end

      test "expiring an approval someone already approved reports completed and changes nothing" do
        @approval_run.mark_completed!

        result = ExpireApprovalActivity.new.execute("step_run_id" => @approval_run.id)

        assert_equal "completed", result["outcome"]
        assert_equal "completed", @approval_run.reload.state
      end

      test "a wait until a time in shared context returns the seconds left" do
        travel_to Time.zone.parse("2026-11-18T09:00:00Z") do
          @run.update!(shared_context: { "campaign" => { "publish_at" => "2026-11-18T10:00:00Z" } })

          result = StartWaitActivity.new.execute("step_run_id" => @wait_run.id)

          assert_equal({ "seconds" => 3600 }, result)
          assert_equal "running", @wait_run.reload.state
        end
      end

      test "a wait until a time already past returns zero" do
        @run.update!(shared_context: { "campaign" => { "publish_at" => "2020-01-01T00:00:00Z" } })

        assert_equal({ "seconds" => 0 }, StartWaitActivity.new.execute("step_run_id" => @wait_run.id))
      end

      test "a wait whose context key is missing fails the step naming the key" do
        result = StartWaitActivity.new.execute("step_run_id" => @wait_run.id)

        assert_match "campaign.publish_at", result["error"]
        assert_equal "failed", @wait_run.reload.state
        assert_equal "wait_invalid_time", @wait_run.error_category
      end

      test "a wait whose context value is not a time fails the step" do
        @run.update!(shared_context: { "campaign" => { "publish_at" => "tomorrow" } })

        result = StartWaitActivity.new.execute("step_run_id" => @wait_run.id)

        assert_match "campaign.publish_at", result["error"]
        assert_equal "wait_invalid_time", @wait_run.reload.error_category
      end

      test "a fixed delay wait returns its delay" do
        @wait_run.step.update!(kind_config: { "delay_seconds" => 90 })

        assert_equal({ "seconds" => 90 }, StartWaitActivity.new.execute("step_run_id" => @wait_run.id))
      end

      test "finishing a wait completes the step run" do
        @wait_run.mark_running!

        assert_equal({ "ok" => true }, FinishWaitActivity.new.execute("step_run_id" => @wait_run.id))
        assert_equal "completed", @wait_run.reload.state
      end

      test "finishing a wait leaves a step run that already ended alone" do
        @wait_run.mark_cancelled!

        FinishWaitActivity.new.execute("step_run_id" => @wait_run.id)

        assert_equal "cancelled", @wait_run.reload.state
      end
    end
  end
end

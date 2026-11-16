# frozen_string_literal: true

require "test_helper"

module PersonalTools
  class ApproveStepRunTest < ActiveSupport::TestCase
    setup do
      @user = create(:user, :with_company)
      @company = @user.companies.first
      @project = create(:project, owner: @user, company: @company)
      @workflow = create(:workflow, scope: @project)
      @run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    end

    def execute
      ApproveStepRun.new(params: { project_id: @project.id, run_id: @run.id }, user: @user).execute
    end

    test "refuses an approval step and leaves it waiting" do
      step = create(:step, workflow: @workflow, position: 1, kind: "approval")
      step_run = create(:step_run, workflow_run: @run, step: step, state: "waiting_input")
      TemporalService.expects(:send_signal).never

      result = execute

      assert_equal 1, result[:exit_code]
      assert_equal "Approval steps are decided by a person on the run page.", result[:stderr]
      assert_equal "waiting_input", step_run.reload.state
    end

    test "refuses a wait step and leaves it running" do
      step = create(:step, workflow: @workflow, position: 1, kind: "wait", kind_config: { "delay_seconds" => 60 })
      step_run = create(:step_run, workflow_run: @run, step: step, state: "running")
      TemporalService.expects(:send_signal).never

      result = execute

      assert_equal 1, result[:exit_code]
      assert_equal "Wait steps continue on their own; skip the step to stop waiting.", result[:stderr]
      assert_equal "running", step_run.reload.state
    end
  end
end

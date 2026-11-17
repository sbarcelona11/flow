# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::WorkflowRunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    @workflow = create(:workflow, scope: @project)
    @credential = create(:agent_credential, user: @user, company: @company)
    sign_in_as(@user)
  end

  test "index redirects into the unified sessions and runs list" do
    create_list(:workflow_run, 2, workflow: @workflow, project: @project, user: @user)

    get company_project_workflow_runs_path(@project)
    assert_redirected_to company_project_sessions_path(@project, type: "run")
  end

  test "show renders workflow run page" do
    run = create(:workflow_run, workflow: @workflow, project: @project, user: @user)

    get company_project_workflow_run_path(@project, run)
    assert_inertia_page "Projects/WorkflowRuns/ShowPage"
  end

  test "create redirects on success" do
    create(:step, workflow: @workflow, position: 1, allow_non_interactive: true)
    mock_workflow_execution_start

    post company_project_workflow_runs_path(@project), params: {
      workflow_run: { workflow_id: @workflow.id, mode: "non_interactive" }
    }
    assert_redirected_to company_project_workflow_run_path(@project, WorkflowRun.sole)
    assert_equal "web", WorkflowRun.sole.source
  end

  test "cancel redirects" do
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    WorkflowService.stubs(:cancel)

    post cancel_company_project_workflow_run_path(@project, run)
    assert_response :redirect
  end

  test "approve_step redirects" do
    step = create(:step, workflow: @workflow, position: 1)
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    create(:step_run, workflow_run: run, step: step, state: "running")
    WorkflowService.stubs(:approve_step)

    post approve_step_company_project_workflow_run_path(@project, run)
    assert_response :redirect
  end

  test "reject_step rejects the approval step and redirects to the run" do
    run, approval_run = parked_approval
    TemporalService.expects(:send_signal).with("workflow-execution-#{run.id}", "step_rejected", approval_run.id).once

    post reject_step_company_project_workflow_run_path(@project, run),
         params: { step_run_id: approval_run.id, note: "Wrong client" }

    assert_redirected_to company_project_workflow_run_path(@project, run)
    approval_run.reload
    assert_equal "failed", approval_run.state
    assert_equal "Rejected by #{@user.name}: Wrong client", approval_run.error_message
  end

  test "reject_step flashes an alert for an approval that was already resolved" do
    run, approval_run = parked_approval
    approval_run.mark_completed!

    post reject_step_company_project_workflow_run_path(@project, run), params: { step_run_id: approval_run.id }

    assert_redirected_to company_project_workflow_run_path(@project, run)
    assert_equal "This approval was already resolved.", flash[:alert]
    assert_equal "completed", approval_run.reload.state
  end

  test "approve_step on an approval step records the approver" do
    run, approval_run = parked_approval
    TemporalService.expects(:send_signal).with("workflow-execution-#{run.id}", "step_completed", approval_run.id).once

    post approve_step_company_project_workflow_run_path(@project, run),
         params: { step_run_id: approval_run.id, note: "Fine" }

    assert_redirected_to company_project_workflow_run_path(@project, run)
    assert_equal "Approved by #{@user.name}: Fine", approval_run.reload.step_note
  end

  test "approve_step on an agent step waiting for input approves it through WorkflowService" do
    step = create(:step, workflow: @workflow, position: 1)
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    waiting = create(:step_run, workflow_run: run, step: step, state: "waiting_input")
    WorkflowService.expects(:approve_step).with(step_run: waiting).once

    post approve_step_company_project_workflow_run_path(@project, run), params: { step_run_id: waiting.id }

    assert_redirected_to company_project_workflow_run_path(@project, run)
    assert_nil flash[:alert]
  end

  test "approve_step refuses a wait step" do
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    wait_step = create(:step, workflow: @workflow, position: 4, kind: "wait", kind_config: { "delay_seconds" => 60 })
    wait_run = create(:step_run, workflow_run: run, step: wait_step, state: "running")
    TemporalService.expects(:send_signal).never

    post approve_step_company_project_workflow_run_path(@project, run), params: { step_run_id: wait_run.id }

    assert_redirected_to company_project_workflow_run_path(@project, run)
    assert_equal "Wait steps continue on their own; skip the step to stop waiting.", flash[:alert]
    assert_equal "running", wait_run.reload.state
  end

  test "a viewer cannot reject" do
    run, approval_run = parked_approval
    viewer = create(:user, :viewer, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    sign_in_as(viewer)

    post reject_step_company_project_workflow_run_path(@project, run), params: { step_run_id: approval_run.id }

    assert_equal "waiting_input", approval_run.reload.state
  end

  test "retry_step redirects" do
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    WorkflowService.stubs(:retry_step).returns(ok: true)

    post retry_step_company_project_workflow_run_path(@project, run)
    assert_response :redirect
  end

  test "retry_step flashes an alert when WorkflowService reports failure" do
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    step_run = create(:step_run, :failed, workflow_run: run)
    WorkflowService.stubs(:retry_step).returns(ok: false, error: "Something went wrong.")

    post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: step_run.id }

    assert_response :redirect
    follow_redirect!
    assert_equal "Something went wrong.", flash[:alert]
  end

  test "retry_step on a failed run starts a new run and redirects to it" do
    run = create(:workflow_run, :failed, workflow: @workflow, project: @project, user: @user)
    step_run = create(:step_run, :failed, workflow_run: run)
    TemporalService.stubs(:workflow_open?).returns(false)
    TemporalWorkflowRegistry.stubs(:start_workflow_execution).returns(ok: true)

    assert_difference("WorkflowRun.count", 1) do
      post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: step_run.id }
    end

    new_run = WorkflowRun.order(:created_at).last
    assert_redirected_to company_project_workflow_run_path(@project, new_run)
    assert_not_equal run.id, new_run.id

    follow_redirect!
    assert_nil flash[:alert]
    # The old run is untouched.
    assert_equal "failed", run.reload.state
  end

  test "approve_step targets the given step_run_id when a run has more than one active step" do
    step_a = create(:step, workflow: @workflow, position: 1)
    step_b = create(:step, workflow: @workflow, position: 2)
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    create(:step_run, workflow_run: run, step: step_a, state: "running")
    second_step_run = create(:step_run, workflow_run: run, step: step_b, state: "waiting_input")

    WorkflowService.expects(:approve_step).with(step_run: second_step_run)

    post approve_step_company_project_workflow_run_path(@project, run), params: { step_run_id: second_step_run.id }
    assert_response :redirect
  end

  test "skip_step targets the given step_run_id when a run has more than one active step" do
    step_a = create(:step, workflow: @workflow, position: 1)
    step_b = create(:step, workflow: @workflow, position: 2)
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    create(:step_run, workflow_run: run, step: step_a, state: "running")
    second_step_run = create(:step_run, workflow_run: run, step: step_b, state: "waiting_input")

    WorkflowService.expects(:skip_step).with(step_run: second_step_run, reason: "not needed")

    post skip_step_company_project_workflow_run_path(@project, run),
         params: { step_run_id: second_step_run.id, reason: "not needed" }
    assert_response :redirect
  end

  test "retry_step 404s when step_run_id belongs to a different run" do
    other_run = create(:workflow_run, workflow: @workflow, project: @project, user: @user)
    foreign_step_run = create(:step_run, :failed, workflow_run: other_run)
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)

    post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: foreign_step_run.id }
    assert_response :not_found
  end

  test "skip_step redirects" do
    step = create(:step, workflow: @workflow, position: 1)
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    create(:step_run, workflow_run: run, step: step, state: "running")
    WorkflowService.stubs(:skip_step)

    post skip_step_company_project_workflow_run_path(@project, run), params: { reason: "skip" }
    assert_response :redirect
  end

  test "viewer collaborator can read index but cannot create a run" do
    viewer = create(:user, :viewer, :onboarding_completed, company: @company,
                                    email: "client@ext.com", password: AuthHelper::TEST_PASSWORD)
    @project.add_collaborator(viewer)
    sign_in_as(viewer)

    get company_project_workflow_runs_path(@project)
    assert_redirected_to company_project_sessions_path(@project, type: "run")

    post company_project_workflow_runs_path(@project), params: {
      workflow_run: { workflow_id: @workflow.id, mode: "non_interactive" }
    }
    assert_response :redirect
    assert_equal 0, WorkflowRun.where(project: @project).count
  end

  test "create without any agent credential starts nothing and says to connect an agent" do
    @credential.destroy!
    create(:step, workflow: @workflow, position: 1)

    post company_project_workflow_runs_path(@project), params: { workflow_run: { workflow_id: @workflow.id } }

    assert_redirected_to company_project_workflow_runs_path(@project)
    assert_equal "No agent credentials. Connect an agent in Profile settings to run workflows.", flash[:alert]
    assert_equal 0, WorkflowRun.count
  end

  test "create refuses a Custom run that switches on auto-run for a step requiring input" do
    step = create(:step, workflow: @workflow, position: 1, name: "Post to Slack", allow_non_interactive: false)

    post company_project_workflow_runs_path(@project), params: {
      workflow_run: { workflow_id: @workflow.id, mode: "mixed", step_overrides: { step.id.to_s => { "autoRun" => true } } }
    }, as: :json

    assert_redirected_to company_project_workflow_runs_path(@project)
    assert_equal "Cannot run automatically: steps Post to Slack require user interaction", flash[:alert]
    assert_equal 0, WorkflowRun.count
  end

  test "create normalizes camelCase step_overrides keys to snake_case" do
    create(:step, workflow: @workflow, position: 1, allow_non_interactive: true)
    mock_workflow_execution_start

    post company_project_workflow_runs_path(@project), params: {
      workflow_run: {
        workflow_id: @workflow.id,
        mode: "mixed",
        step_overrides: { "1" => { "autoRun" => true } }
      }
    }, as: :json

    assert_response :redirect
    assert_equal({ "1" => { "auto_run" => true } }, WorkflowRun.last.step_overrides)
  end

  test "create passes through already snake_case step_overrides keys unchanged" do
    create(:step, workflow: @workflow, position: 1, allow_non_interactive: true)
    mock_workflow_execution_start

    post company_project_workflow_runs_path(@project), params: {
      workflow_run: {
        workflow_id: @workflow.id,
        mode: "mixed",
        step_overrides: { "1" => { "auto_run" => true } }
      }
    }, as: :json

    assert_response :redirect
    assert_equal({ "1" => { "auto_run" => true } }, WorkflowRun.last.step_overrides)
  end

  test "create keeps only auto_run in a step override and drops unknown value fields (F16)" do
    create(:step, workflow: @workflow, position: 1, allow_non_interactive: true)
    mock_workflow_execution_start

    post company_project_workflow_runs_path(@project), params: {
      workflow_run: {
        workflow_id: @workflow.id,
        mode: "mixed",
        step_overrides: { "1" => { "auto_run" => true, "requested_model" => "sneaky", "evil" => { "x" => 1 } } }
      }
    }, as: :json

    assert_response :redirect
    assert_equal({ "1" => { "auto_run" => true } }, WorkflowRun.last.step_overrides)
  end

  test "approve_step and reject_step refuse an action step" do
    run, action_run = run_with_sent_action(state: :running)
    action_run.update!(state: "running")
    TemporalService.expects(:send_signal).never

    %i[approve_step reject_step].each do |action|
      post public_send("#{action}_company_project_workflow_run_path", @project, run), params: { step_run_id: action_run.id }

      assert_redirected_to company_project_workflow_run_path(@project, run)
      assert_equal "Action steps finish on their own; skip the step to stop waiting for it.", flash[:alert]
    end
    assert_equal "running", action_run.reload.state
  end

  test "retry_step refuses a run that already sent an action until the resend is confirmed" do
    run, action_run = run_with_sent_action(outcome: "unknown")
    TemporalService.stubs(:workflow_open?).returns(false)

    assert_no_difference("WorkflowRun.count") do
      post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: action_run.id }
    end

    assert_redirected_to company_project_workflow_run_path(@project, run)
    assert_equal "This retry would send these actions again: Billing Invoice · create_invoice. Check them, then confirm.",
                 flash[:alert]
  end

  test "retry_step with confirm_resend retries a run that already sent an action" do
    run, action_run = run_with_sent_action
    TemporalService.stubs(:workflow_open?).returns(false)
    TemporalWorkflowRegistry.stubs(:start_workflow_execution).returns(ok: true)

    assert_difference("WorkflowRun.count", 1) do
      post retry_step_company_project_workflow_run_path(@project, run),
           params: { step_run_id: action_run.id, confirm_resend: "true" }
    end

    assert_nil flash[:alert]
  end

  test "retry_step on an open run asks only about the actions of the step it retries" do
    run, action_run = run_with_sent_action(state: :running)
    _, other_run = run_with_sent_action(name: "Refund")
    other_run.update!(workflow_run: run)
    TemporalService.stubs(:workflow_open?).returns(true)
    TemporalService.expects(:send_signal).never

    post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: action_run.id }

    assert_equal "This retry would send these actions again: Billing Invoice · create_invoice. Check them, then confirm.",
                 flash[:alert]
  end

  test "retry_step on an open run retries in place without asking when the retried step sent nothing" do
    run, = run_with_sent_action(state: :running)
    quiet_step = create(:step, workflow: @workflow, position: 50, name: "Quiet")
    quiet_run = create(:step_run, :failed, workflow_run: run, step: quiet_step)
    TemporalService.stubs(:workflow_open?).returns(true)
    TemporalService.expects(:send_signal).with(run.execution_workflow_id, "step_retried", anything).returns(ok: true)

    post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: quiet_run.id }

    assert_nil flash[:alert]
  end

  test "retry_step on a closed run asks about every action the new run would send again" do
    run, action_run = run_with_sent_action
    _, other_run = run_with_sent_action(name: "Refund")
    other_run.update!(workflow_run: run)
    TemporalService.stubs(:workflow_open?).returns(false)

    assert_no_difference("WorkflowRun.count") do
      post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: action_run.id }
    end

    assert_equal "This retry would send these actions again: Billing Invoice · create_invoice, Billing Refund · create_invoice. " \
                 "Check them, then confirm.", flash[:alert]
  end

  test "retry_step needs no confirmation for a read action or one that failed before sending" do
    %w[read].each do |effect|
      run, action_run = run_with_sent_action(effect: effect, name: "Lookup")
      TemporalService.stubs(:workflow_open?).returns(false)
      TemporalWorkflowRegistry.stubs(:start_workflow_execution).returns(ok: true)

      assert_difference("WorkflowRun.count", 1) do
        post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: action_run.id }
      end
    end
    run, action_run = run_with_sent_action(outcome: "failed", name: "Failed")

    assert_difference("WorkflowRun.count", 1) do
      post retry_step_company_project_workflow_run_path(@project, run), params: { step_run_id: action_run.id }
    end
  end

  private

  def run_with_sent_action(outcome: "succeeded", effect: "write", state: :failed, name: "Invoice")
    server = create(:mcp_server, :with_tool_schemas, scope: @project, name: "Billing #{name}",
                                                     snapshot_tools: [ { "name" => "create_invoice" },
                                                                       { "name" => "list_invoices", "annotations" => { "readOnlyHint" => true } } ])
    tool = effect == "read" ? "list_invoices" : "create_invoice"
    run = create(:workflow_run, state, workflow: @workflow, project: @project, user: @user)
    config = { "target" => "mcp_tool", "mcp_server_id" => server.id, "tool" => tool, "effect" => effect }
    action = with_feature(:workflow_action_steps, true, company: @company) do
      create(:step, workflow: @workflow, position: @workflow.steps.count + 10, name: name, kind: "action", kind_config: config)
    end
    action_run = create(:step_run, :failed, workflow_run: run, step: action)
    ActionCall.create!(step_run: action_run, target_type: "mcp_tool", mcp_server: server, tool_name: tool,
                       effect: effect, arguments: {}, attempted_at: Time.current).finish!(outcome: outcome)
    [ run, action_run ]
  end

  def parked_approval
    step = create(:step, workflow: @workflow, position: 3, kind: "approval")
    run = create(:workflow_run, :running, workflow: @workflow, project: @project, user: @user)
    [ run, create(:step_run, workflow_run: run, step: step, state: "waiting_input") ]
  end
end

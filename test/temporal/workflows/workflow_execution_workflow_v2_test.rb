# frozen_string_literal: true

require "test_helper"

module Workflows
  class QueueWaitProbe < WorkflowExecutionWorkflowV2
    def run(_input)
      @step_decisions = {}
      @cancelled = false
      started = Temporalio::Workflow.now
      wait_for_signal(1)
      { "decision" => @step_decisions[1].to_s, "waited" => Temporalio::Workflow.now - started }
    end

    private

    # A deterministic stand-in for a slow queue; the production wait loop and
    # SDK timers are real. Time-skipping makes this a fast 25-hour regression.
    def refresh_session_decisions(_ids)
      Temporalio::Workflow.sleep(90_000)
      @step_decisions[1] = :completed
    end
  end

  # Nothing ever resolves here, so the wait is pure polling — which is exactly
  # the shape that used to spend a run's whole history budget.
  class BackoffProbe < WorkflowExecutionWorkflowV2
    def run(_input)
      @step_decisions = {}
      @cancelled = false
      @refreshes = 0
      started = Temporalio::Workflow.now
      wait_for_signal(1)
      { "refreshes" => @refreshes, "waited" => Temporalio::Workflow.now - started }
    end

    private

    def refresh_session_decisions(_ids)
      @refreshes += 1
      @step_decisions[1] = :completed if @refreshes >= 5
    end
  end

  # The status the database reports for a step whose Skip was written but whose
  # signal never arrived.
  class SkippedInDatabaseActivity < Temporalio::Activity::Definition
    activity_name "workflow_step_session_status_activity"
    def execute(_input = nil)
      { "cancelled" => false, "sessions" => { "1" => { "state" => "ready", "step_state" => "skipped" } } }
    end
  end

  class DatabaseDecisionProbe < WorkflowExecutionWorkflowV2
    def run(_input)
      wait_for_signal(1)
      { "decision" => @step_decisions[1].to_s }
    end
  end

  class ControlStepProbe < WorkflowExecutionWorkflowV2
    STEP_RUN_ID = 1

    def run(input)
      @workflow_run_id = 10
      @step_failure_counts = {}
      @quota_error_step_run_ids = {}
      @auth_error_step_run_ids = {}
      @mode = input["mode"] || "interactive"
      @input = input
      @refreshes = 0
      @complete_step_calls = 0
      @finish_calls = 0
      started = Temporalio::Workflow.now
      outcome = run_control_step(step_data(input))
      { "outcome" => outcome.to_s, "waited" => Temporalio::Workflow.now - started,
        "complete_step_calls" => @complete_step_calls, "finish_calls" => @finish_calls }
    end

    private

    def step_data(input)
      { "step_id" => 5, "step_run_id" => STEP_RUN_ID, "kind" => "approval", "auto_run" => true,
        "on_failure" => input["on_failure"] || "fail" }
    end

    def run_control_step(step_data)
      run_approval(step_data, STEP_RUN_ID)
    end

    def open_approval(_step_run_id) = { "timeout_seconds" => 3600, "on_timeout" => "fail" }
    def expire_approval(_step_run_id) = { "outcome" => "failed" }
    def mark_step_skipped(_step_run_id, _reason = nil) = nil

    def complete_step(_step_run_id)
      @complete_step_calls += 1
      :completed
    end
  end

  class UnansweredApprovalProbe < ControlStepProbe
    private

    def refresh_session_decisions(_ids) = nil
  end

  class ApprovedApprovalProbe < ControlStepProbe
    private

    def refresh_session_decisions(_ids)
      @step_decisions[STEP_RUN_ID] = :completed
    end
  end

  # The status the database reports for an approval step a person rejected:
  # the step failed, and it never had a session.
  class RejectedInDatabaseActivity < Temporalio::Activity::Definition
    activity_name "workflow_step_session_status_activity"
    def execute(_input = nil)
      { "cancelled" => false, "sessions" => { "1" => { "state" => nil, "step_state" => "failed" } } }
    end
  end

  class RejectedApprovalProbe < ControlStepProbe; end

  class NonInteractiveApprovalProbe < ControlStepProbe
    private

    def refresh_session_decisions(_ids)
      @refreshes += 1
      @step_decisions[STEP_RUN_ID] = :completed if @refreshes == 3
    end
  end

  class CancelledApprovalProbe < ControlStepProbe
    private

    def refresh_session_decisions(_ids)
      @cancelled = true
    end
  end

  class WaitProbe < ControlStepProbe
    private

    def run_control_step(step_data)
      run_wait(step_data.merge("kind" => "wait"), STEP_RUN_ID)
    end

    def start_wait(_step_run_id) = { "seconds" => @input["seconds"] }

    def finish_wait(_step_run_id)
      @finish_calls += 1
      { "ok" => true }
    end
  end

  class InvalidWaitProbe < WaitProbe
    private

    def start_wait(_step_run_id) = { "error" => "Wait time not found" }
  end

  # The main loop hands every ready step to execute_steps_parallel, so a control
  # step must be routed there too, not only through execute_step.
  class ControlStepBatchProbe < WorkflowExecutionWorkflowV2
    def run(_input)
      @workflow_run_id = 10
      @step_failure_counts = {}
      @quota_error_step_run_ids = {}
      @auth_error_step_run_ids = {}
      @mode = "interactive"
      @launched = []
      @prepared = []
      steps = [
        { "step_id" => 1, "step_run_id" => 11, "kind" => "agent", "on_failure" => "fail" },
        { "step_id" => 2, "step_run_id" => 12, "kind" => "approval", "on_failure" => "fail" }
      ]
      results = execute_steps_parallel(steps)
      { "results" => results.transform_keys(&:to_s).transform_values(&:to_s),
        "launched" => @launched, "prepared" => @prepared }
    end

    private

    def policy_skip(_step_data) = nil

    def prepare_step(step_run_id)
      @prepared << step_run_id
      :ok
    end

    def launch_step_session(step_run_id) = @launched << step_run_id
    def open_approval(_step_run_id) = { "timeout_seconds" => 3600, "on_timeout" => "fail" }
    def complete_step(_step_run_id) = :completed

    def refresh_session_decisions(ids)
      ids.each { |id| @step_decisions[id] = :completed }
    end
  end

  class WorkflowExecutionWorkflowV2Test < ActiveSupport::TestCase
    test "an approval no one answers expires after its timeout" do
      result = run_workflow(UnansweredApprovalProbe, {}, activities: [], task_queue: "approval-timeout-test")
      assert_equal "failed", result["outcome"]
      assert_operator result["waited"], :>=, 3600
    end

    test "an approval approved in the database completes without calling complete_step" do
      result = run_workflow(ApprovedApprovalProbe, {}, activities: [], task_queue: "approval-ok-test")
      assert_equal "completed", result["outcome"]
      assert_equal 0, result["complete_step_calls"]
    end

    test "a rejected approval follows on_failure skip" do
      proxy = Object.new
      proxy.define_singleton_method(:workflow_step_session_status_activity) do
        TemporalWorkflowHelper::ActivityRef.new("workflow_step_session_status_activity", "approval-reject-test")
      end
      RejectedApprovalProbe.stubs(:_preloaded_activities).returns(proxy)

      result = run_workflow(RejectedApprovalProbe, { "on_failure" => "skip" },
                            activities: [ RejectedInDatabaseActivity ], task_queue: "approval-reject-test")
      assert_equal "skipped", result["outcome"]
      assert_operator result["waited"], :<, 3600
    end

    test "an approval waits for a person even in a non_interactive run" do
      result = run_workflow(NonInteractiveApprovalProbe, { "mode" => "non_interactive" },
                            activities: [], task_queue: "approval-nonint-test")
      assert_equal "completed", result["outcome"]
      assert_operator result["waited"], :>=, 90 # the scripted decision arrives at the third poll
    end

    test "a cancelled run stops waiting on an approval" do
      result = run_workflow(CancelledApprovalProbe, {}, activities: [], task_queue: "approval-cancel-test")
      assert_equal "cancelled", result["outcome"]
    end

    test "a wait step sleeps for the seconds start_wait returns, then finishes" do
      result = run_workflow(WaitProbe, { "seconds" => 7200 }, activities: [], task_queue: "wait-test")
      assert_equal "completed", result["outcome"]
      assert_operator result["waited"], :>=, 7200
      assert_equal 1, result["finish_calls"]
    end

    test "a wait of zero seconds proceeds at once" do
      result = run_workflow(WaitProbe, { "seconds" => 0 }, activities: [], task_queue: "wait-zero-test")
      assert_equal "completed", result["outcome"]
      assert_operator result["waited"], :<, 1
    end

    test "a wait whose time is invalid fails without waiting" do
      result = run_workflow(InvalidWaitProbe, {}, activities: [], task_queue: "wait-invalid-test")
      assert_equal "failed", result["outcome"]
    end

    test "a rejection signalled before the run starts is kept" do
      workflow = WorkflowExecutionWorkflowV2.new
      workflow.step_rejected(7)
      assert_equal({ 7 => :rejected }, workflow.instance_variable_get(:@step_decisions))
    end

    test "a control step in a batch runs without a session while its agent sibling launches" do
      result = run_workflow(ControlStepBatchProbe, {}, activities: [], task_queue: "control-batch-test")
      assert_equal({ "1" => "completed", "2" => "completed" }, result["results"])
      assert_equal [ 11 ], result["prepared"]
      assert_equal [ 11 ], result["launched"]
    end

    test "queue waiting can exceed the legacy 23-hour parent timeout" do
      result = run_workflow(QueueWaitProbe, {}, activities: [], task_queue: "queue-wait-test")
      assert_equal "completed", result["decision"]
      assert_operator result["waited"], :>=, 90_000
    end

    test "an idle wait backs off instead of polling on a fixed interval forever" do
      result = run_workflow(BackoffProbe, {}, activities: [], task_queue: "backoff-test")

      assert_equal 5, result["refreshes"]
      # 30 + 60 + 120 + 240 seconds of timers between the five durable reads.
      assert_operator result["waited"], :>=, 450
    end

    test "a Skip written to the step is honoured without its signal" do
      proxy = Object.new
      proxy.define_singleton_method(:workflow_step_session_status_activity) do
        TemporalWorkflowHelper::ActivityRef.new("workflow_step_session_status_activity", "db-decision-test")
      end
      DatabaseDecisionProbe.stubs(:_preloaded_activities).returns(proxy)

      result = run_workflow(DatabaseDecisionProbe, {}, activities: [ SkippedInDatabaseActivity ],
                                                       task_queue: "db-decision-test")

      assert_equal "skipped", result["decision"]
    end

    # A signal can reach a handler before `run` has executed at all.
    test "a decision signalled before the run starts is kept, not wiped or crashed on" do
      workflow = WorkflowExecutionWorkflow.new
      workflow.step_skipped(7)

      assert_equal({ 7 => :skipped }, workflow.instance_variable_get(:@step_decisions))
    end

    test "early container completion signals cannot advance an admitted parent" do
      workflow = WorkflowExecutionWorkflowV2.new
      workflow.instance_variable_set(:@step_decisions, { 1 => nil })
      workflow.container_finished(1)
      assert_nil workflow.instance_variable_get(:@step_decisions)[1]
    end
  end
end

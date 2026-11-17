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

    def open_approval(*) = { "timeout_seconds" => 3600, "on_timeout" => "fail" }
    def expire_approval(*) = { "outcome" => "failed" }
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

    def start_wait(*) = { "seconds" => @input["seconds"] }
    def refresh_session_decisions(_ids) = @refreshes += 1

    def finish_wait(_step_run_id)
      @finish_calls += 1
      { "ok" => true }
    end
  end

  # The step run ended while the wait ran; finish_wait reports the state it found.
  class EndedDuringWaitProbe < WaitProbe
    private

    def finish_wait(_step_run_id)
      @finish_calls += 1
      { "ok" => true, "state" => @input["finished_state"] }
    end
  end

  # A cancel whose signal was lost: only the durable read sees it.
  class CancelledMidWaitProbe < WaitProbe
    private

    def refresh_session_decisions(_ids)
      @refreshes += 1
      @cancelled = true if @refreshes == 3
    end
  end

  # The status the database reports for a wait step whose run was cancelled.
  class CancelledInDatabaseActivity < Temporalio::Activity::Definition
    activity_name "workflow_step_session_status_activity"
    def execute(_input = nil)
      { "cancelled" => true, "sessions" => { "1" => { "state" => nil, "step_state" => "cancelled" } } }
    end
  end

  class AlreadyCancelledWaitProbe < ControlStepProbe
    private

    def run_control_step(step_data)
      run_wait(step_data.merge("kind" => "wait"), STEP_RUN_ID)
    end

    def start_wait(*) = { "seconds" => 0 }

    def finish_wait(_step_run_id)
      @finish_calls += 1
      { "ok" => true }
    end
  end

  class InvalidWaitProbe < WaitProbe
    private

    def start_wait(*) = { "error" => "Wait time not found" }
  end

  # The main loop hands every ready step to execute_steps_parallel, so a control
  # step must be routed there too, not only through execute_step.
  class ApprovalWithoutTimeoutProbe < UnansweredApprovalProbe
    private

    def open_approval(*) = { "on_timeout" => "fail" }
  end

  class WaitWithoutSecondsProbe < WaitProbe
    private

    def start_wait(*) = {}
  end

  class EchoKindConfigActivity < Temporalio::Activity::Definition
    activity_name "workflow_open_approval_activity"
    def execute(input)
      input["kind_config"]
    end
  end

  class RecordedConfigApprovalProbe < UnansweredApprovalProbe
    private

    def step_data(input)
      super.merge("kind_config" => { "timeout_seconds" => 60, "on_timeout" => "fail" })
    end

    def open_approval(step_run_id, kind_config)
      execute_activity(activities.workflow_open_approval_activity,
        { step_run_id: step_run_id, kind_config: kind_config }, start_to_close_timeout: 30)
    end
  end

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
    def open_approval(*) = { "timeout_seconds" => 3600, "on_timeout" => "fail" }
    def complete_step(_step_run_id) = :completed

    def refresh_session_decisions(ids)
      ids.each { |id| @step_decisions[id] = :completed }
    end
  end

  class ActionProbe < ControlStepProbe
    def run(input)
      @status_calls = 0
      super.merge("status_calls" => @status_calls, "finish_stopped" => @finish_stopped)
    end

    private

    def step_data(input)
      super.merge("kind" => "action", "kind_config" => { "effect" => input["effect"] || "write" })
    end

    def run_control_step(step_data)
      run_action(step_data, STEP_RUN_ID)
    end

    def start_action(*args) = @input["start"] || super
    def refresh_session_decisions(_ids) = @refreshes += 1

    def action_status(_tool_result_id)
      @status_calls += 1
      states = @input["states"]
      { "state" => states[[ @status_calls, states.size ].min - 1] }
    end

    def finish_action(_step_data, _step_run_id, _tool_result_id, stopped)
      @finish_calls += 1
      @finish_stopped = stopped
      { "outcome" => stopped || @input["finish"] }
    end
  end

  class SkippedMidActionProbe < ActionProbe
    private

    def refresh_session_decisions(_ids)
      @refreshes += 1
      @step_decisions[STEP_RUN_ID] = :skipped if @refreshes == 2
    end
  end

  # A Complete or Retry aimed at an action step must not end its wait.
  class OtherDecisionMidActionProbe < ActionProbe
    private

    def refresh_session_decisions(_ids)
      @refreshes += 1
      @step_decisions[STEP_RUN_ID] = @input["decision"].to_sym
    end
  end

  # A cancel whose signal was lost: only the durable read sees it.
  class CancelledMidActionProbe < ActionProbe
    private

    def refresh_session_decisions(_ids)
      @refreshes += 1
      @cancelled = true if @refreshes == 2
    end
  end

  # Mirrors StartActionActivity's guard: a side-effecting call is sent on the
  # first attempt only, and a later attempt fails the step as outcome unknown.
  class FailingStartActionActivity < Temporalio::Activity::Definition
    activity_name "workflow_start_action_activity"
    CALLS = Concurrent::AtomicFixnum.new
    SENT = Concurrent::AtomicFixnum.new

    def execute(input)
      CALLS.increment
      return { "mode" => "done", "outcome" => "failed" } if input["kind_config"]["effect"] != "read" && SENT.value.positive?

      SENT.increment
      raise Temporalio::Error::ApplicationError, "connection reset after the call was sent"
    end

    def self.reset!
      CALLS.value = 0
      SENT.value = 0
    end
  end

  class UnretriedStartProbe < ActionProbe
    private

    def run_control_step(step_data)
      run_action(step_data, STEP_RUN_ID)
    rescue Temporalio::Error::ActivityError
      :raised
    end
  end

  class EchoStartActionActivity < Temporalio::Activity::Definition
    activity_name "workflow_start_action_activity"

    def execute(input)
      recorded = input["kind_config"] == { "effect" => "write" } && input["depends_on_step_ids"] == [ 4 ]
      { "mode" => "done", "outcome" => recorded ? "completed" : "failed" }
    end
  end

  class RecordedConfigActionProbe < UnretriedStartProbe
    private

    def step_data(input) = super.merge("depends_on_step_ids" => [ 4 ])
  end

  class ActionBatchProbe < ControlStepBatchProbe
    def run(_input)
      @workflow_run_id = 10
      @step_failure_counts = {}
      @quota_error_step_run_ids = {}
      @auth_error_step_run_ids = {}
      @mode = "non_interactive"
      @launched = []
      @prepared = []
      steps = [
        { "step_id" => 1, "step_run_id" => 11, "kind" => "agent", "on_failure" => "fail" },
        { "step_id" => 2, "step_run_id" => 12, "kind" => "action", "kind_config" => { "effect" => "write" },
          "on_failure" => "fail" }
      ]
      results = execute_steps_parallel(steps)
      { "results" => results.transform_keys(&:to_s).transform_values(&:to_s),
        "launched" => @launched, "prepared" => @prepared }
    end

    private

    def start_action(*) = { "mode" => "done", "outcome" => "completed" }
  end

  class WorkflowExecutionWorkflowV2Test < ActiveSupport::TestCase
    def stub_activity(probe, name, task_queue)
      proxy = Object.new
      proxy.define_singleton_method(name) { TemporalWorkflowHelper::ActivityRef.new(name.to_s, task_queue) }
      probe.stubs(:_preloaded_activities).returns(proxy)
    end

    def async_start(deadline_seconds)
      { "mode" => "async", "tool_result_id" => 77, "deadline_seconds" => deadline_seconds }
    end

    test "a done action completes without polling" do
      result = run_workflow(ActionProbe, { "start" => { "mode" => "done", "outcome" => "completed" } },
                            activities: [], task_queue: "action-done-test")
      assert_equal "completed", result["outcome"]
      assert_equal 0, result["status_calls"]
      assert_equal 0, result["finish_calls"]
      assert_operator result["waited"], :<, 1
    end

    test "a failed action follows on_failure skip" do
      result = run_workflow(ActionProbe, { "start" => { "mode" => "done", "outcome" => "failed" }, "on_failure" => "skip" },
                            activities: [], task_queue: "action-failed-test")
      assert_equal "skipped", result["outcome"]
    end

    test "an action whose step run ended meanwhile reports that state" do
      { "skipped" => "skipped", "cancelled" => "cancelled" }.each do |state, outcome|
        result = run_workflow(ActionProbe, { "start" => { "mode" => "done", "outcome" => state } },
                              activities: [], task_queue: "action-ended-#{state}-test")
        assert_equal outcome, result["outcome"], "start_action reporting #{state}"
      end
    end

    test "an async action polls until the Wrapper finishes" do
      result = run_workflow(ActionProbe, { "start" => async_start(420), "states" => %w[processing processing completed],
                                           "finish" => "completed" },
                            activities: [], task_queue: "action-async-test")
      assert_equal "completed", result["outcome"]
      assert_equal 3, result["status_calls"]
      assert_equal 1, result["finish_calls"]
      assert_operator result["waited"], :>=, 90 # 30 + 60 seconds of backoff between the three reads
      assert_operator result["waited"], :<, 420
    end

    test "an async action past its deadline fails" do
      result = run_workflow(ActionProbe, { "start" => async_start(100), "states" => %w[processing], "finish" => "failed" },
                            activities: [], task_queue: "action-deadline-test")
      assert_equal "failed", result["outcome"]
      assert_equal 1, result["finish_calls"]
      assert_operator result["waited"], :>=, 100
      assert_operator result["waited"], :<, 130
    end

    test "a cancelled run stops waiting on an action and closes its call" do
      result = run_workflow(CancelledMidActionProbe, { "start" => async_start(420), "states" => %w[processing] },
                            activities: [], task_queue: "action-cancel-test")
      assert_equal "cancelled", result["outcome"]
      assert_equal 1, result["finish_calls"]
      assert_equal "cancelled", result["finish_stopped"]
      assert_operator result["waited"], :<, 420
    end

    test "a skip during an async action stops waiting and closes its call" do
      result = run_workflow(SkippedMidActionProbe, { "start" => async_start(420), "states" => %w[processing] },
                            activities: [], task_queue: "action-skip-test")
      assert_equal "skipped", result["outcome"]
      assert_equal 1, result["finish_calls"]
      assert_equal "skipped", result["finish_stopped"]
      assert_operator result["waited"], :<, 420
    end

    test "an async action keeps waiting through a decision that is not a skip or cancel" do
      %w[completed rejected retried].each do |decision|
        result = run_workflow(OtherDecisionMidActionProbe,
                              { "start" => async_start(420), "states" => %w[processing processing completed],
                                "finish" => "completed", "decision" => decision },
                              activities: [], task_queue: "action-other-decision-#{decision}-test")
        assert_equal "completed", result["outcome"], decision
        assert_equal 3, result["status_calls"], decision
        assert_nil result["finish_stopped"], decision
      end
    end

    test "an unexpected action outcome fails the workflow instead of passing for a cancel" do
      error = assert_raises(Temporalio::Error::WorkflowFailedError) do
        run_workflow(ActionProbe, { "start" => { "mode" => "done", "outcome" => "running" } },
                     activities: [], task_queue: "action-unexpected-test")
      end
      assert_equal 'Unknown action outcome: "running"', error.cause.message
    end

    test "an irreversible action's start is attempted again only to fail as outcome unknown" do
      stub_activity(UnretriedStartProbe, :workflow_start_action_activity, "action-no-retry-test")
      FailingStartActionActivity.reset!

      result = run_workflow(UnretriedStartProbe, { "effect" => "irreversible" },
                            activities: [ FailingStartActionActivity ], task_queue: "action-no-retry-test")
      assert_equal "failed", result["outcome"]
      assert_equal 2, FailingStartActionActivity::CALLS.value
      assert_equal 1, FailingStartActionActivity::SENT.value
    end

    test "a read action's start activity is retried" do
      stub_activity(UnretriedStartProbe, :workflow_start_action_activity, "action-read-retry-test")
      FailingStartActionActivity.reset!

      result = run_workflow(UnretriedStartProbe, { "effect" => "read" },
                            activities: [ FailingStartActionActivity ], task_queue: "action-read-retry-test")
      assert_equal "raised", result["outcome"]
      assert_equal 5, FailingStartActionActivity::CALLS.value
    end

    test "an action starts with the config and dependencies recorded in the step list" do
      stub_activity(RecordedConfigActionProbe, :workflow_start_action_activity, "action-recorded-test")

      result = run_workflow(RecordedConfigActionProbe, {}, activities: [ EchoStartActionActivity ],
                                                           task_queue: "action-recorded-test")
      assert_equal "completed", result["outcome"]
    end

    test "an action runs in the same batch as an agent step" do
      result = run_workflow(ActionBatchProbe, {}, activities: [], task_queue: "action-batch-test")
      assert_equal({ "1" => "completed", "2" => "completed" }, result["results"])
      assert_equal [ 11 ], result["prepared"]
      assert_equal [ 11 ], result["launched"]
    end

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

    test "a wait reports the state finish_wait found, not always completed" do
      { "skipped" => "skipped", "cancelled" => "cancelled", "failed" => "failed", "completed" => "completed" }
        .each do |state, outcome|
          result = run_workflow(EndedDuringWaitProbe, { "seconds" => 60, "finished_state" => state },
                                activities: [], task_queue: "wait-ended-#{state}-test")
          assert_equal outcome, result["outcome"], "finish_wait reporting #{state}"
        end
    end

    test "a wait of zero seconds proceeds at once" do
      result = run_workflow(WaitProbe, { "seconds" => 0 }, activities: [], task_queue: "wait-zero-test")
      assert_equal "completed", result["outcome"]
      assert_operator result["waited"], :<, 1
    end

    test "a wait sees a cancel whose signal was lost and stops without finishing" do
      result = run_workflow(CancelledMidWaitProbe, { "seconds" => 7200 }, activities: [], task_queue: "wait-cancel-test")
      assert_equal "cancelled", result["outcome"]
      assert_equal 0, result["finish_calls"]
      assert_operator result["waited"], :<, 7200
    end

    test "a wait of zero seconds on a step run already cancelled stops without finishing" do
      proxy = Object.new
      proxy.define_singleton_method(:workflow_step_session_status_activity) do
        TemporalWorkflowHelper::ActivityRef.new("workflow_step_session_status_activity", "wait-cancelled-test")
      end
      AlreadyCancelledWaitProbe.stubs(:_preloaded_activities).returns(proxy)

      result = run_workflow(AlreadyCancelledWaitProbe, { "seconds" => 0 },
                            activities: [ CancelledInDatabaseActivity ], task_queue: "wait-cancelled-test")
      assert_equal "cancelled", result["outcome"]
      assert_equal 0, result["finish_calls"]
    end

    test "a wait whose time is invalid fails without waiting" do
      result = run_workflow(InvalidWaitProbe, {}, activities: [], task_queue: "wait-invalid-test")
      assert_equal "failed", result["outcome"]
    end

    test "an approval whose config has no timeout fails instead of crashing the workflow task" do
      result = run_workflow(ApprovalWithoutTimeoutProbe, {}, activities: [], task_queue: "approval-no-timeout-test")
      assert_equal "failed", result["outcome"]
      assert_operator result["waited"], :<, 1
    end

    test "a wait whose start returns no seconds fails without finishing" do
      result = run_workflow(WaitWithoutSecondsProbe, {}, activities: [], task_queue: "wait-no-seconds-test")
      assert_equal "failed", result["outcome"]
      assert_equal 0, result["finish_calls"]
    end

    test "an approval opens with the config recorded in the step list" do
      proxy = Object.new
      proxy.define_singleton_method(:workflow_open_approval_activity) do
        TemporalWorkflowHelper::ActivityRef.new("workflow_open_approval_activity", "approval-recorded-config-test")
      end
      RecordedConfigApprovalProbe.stubs(:_preloaded_activities).returns(proxy)

      result = run_workflow(RecordedConfigApprovalProbe, {}, activities: [ EchoKindConfigActivity ],
                                                             task_queue: "approval-recorded-config-test")
      assert_equal "failed", result["outcome"]
      assert_operator result["waited"], :>=, 60
      assert_operator result["waited"], :<, 3600
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

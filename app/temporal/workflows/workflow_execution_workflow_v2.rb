# frozen_string_literal: true

module Workflows
  # Parent workflow for runs whose step sessions go through the admission queue.
  #
  # A queued step has no container and no signal source yet, so the parent can no
  # longer treat "the container told me it finished" as the completion event.
  # Instead the database is the authority and signals are demoted to wake-ups:
  # they cut the latency of the next durable read to zero without letting a
  # session that has not yet returned its capacity advance the run.
  #
  # Polling backs off because history is finite. A step that is genuinely waiting
  # on a human for a week must not spend the run's 51,200-event budget on
  # thirty-second heartbeats — and it does not have to, because every event that
  # actually changes a session's state also signals.
  class WorkflowExecutionWorkflowV2 < WorkflowExecutionWorkflow
    INITIAL_POLL_INTERVAL = 30
    MAX_POLL_INTERVAL = 900
    SESSIONLESS_KINDS = %w[approval wait action].freeze

    # Container-lifecycle signals arrive before runtime cleanup finishes, so they
    # are a wake-up, not a verdict.
    workflow_signal
    def container_finished(_step_run_id = nil)
      @session_wake = true
    end

    workflow_signal
    def step_rejected(step_run_id = nil)
      target = step_run_id || @current_interactive_step_run_id
      @step_decisions[target] = :rejected if target
    end

    private

    def execute_steps_parallel(steps)
      control, agents = steps.partition { |step_data| sessionless_step?(step_data) }
      return super if control.empty?

      runs = control.map do |step_data|
        Temporalio::Workflow::Future.new { [ step_data["step_id"], execute_step(step_data) ] }
      end
      results = agents.empty? ? {} : super(agents)
      runs.each { |run| results.store(*run.wait) }
      results
    end

    def execute_step(step_data)
      return super unless sessionless_step?(step_data)

      skip = policy_skip(step_data)
      return skip_by_policy(step_data, skip["reason"]) if skip

      step_id = step_data["step_id"]
      step_run_id = @retry_overrides.delete(step_id) || step_data["step_run_id"] || create_step_run(step_data)
      @step_run_to_step_id[step_run_id] = step_id
      case step_data["kind"]
      when "approval" then run_approval(step_data, step_run_id)
      when "wait" then run_wait(step_data, step_run_id)
      else run_action(step_data, step_run_id)
      end
    end

    def sessionless_step?(step_data)
      SESSIONLESS_KINDS.include?(step_data["kind"])
    end

    def run_approval(step_data, step_run_id)
      (@control_step_run_ids ||= []) << step_run_id
      config = open_approval(step_run_id, step_data["kind_config"])
      timeout = config["timeout_seconds"]
      return recover_from_step_failure(step_data, step_run_id) unless timeout.is_a?(Numeric)

      decided = await_decision_until(step_run_id, Temporalio::Workflow.now + timeout)
      return :cancelled if @cancelled
      return approval_outcome(step_data, step_run_id, @step_decisions[step_run_id]) if decided

      case expire_approval(step_run_id, step_data["kind_config"])["outcome"]
      when "failed" then recover_from_step_failure(step_data, step_run_id)
      when "skipped" then :skipped
      when "completed" then :completed
      else :cancelled
      end
    end

    def approval_outcome(step_data, step_run_id, decision)
      case decision
      when :completed then :completed
      when :skipped then :skipped
      when :rejected then recover_from_step_failure(step_data, step_run_id)
      when :retried then execute_step(step_data)
      else :cancelled
      end
    end

    # await_session_change rescues Timeout::Error for its own backoff, so an
    # outer Workflow.timeout around it would never fire; the deadline bounds each
    # poll interval instead.
    def await_decision_until(step_run_id, deadline)
      interval = INITIAL_POLL_INTERVAL
      loop do
        refresh_session_decisions([ step_run_id ])
        return true if @step_decisions[step_run_id] || @cancelled

        left = deadline - Temporalio::Workflow.now
        return false if left <= 0

        begin
          Temporalio::Workflow.timeout([ interval, left ].min) do
            Temporalio::Workflow.wait_condition { @step_decisions[step_run_id] || @cancelled }
          end
          return true
        rescue Timeout::Error
          interval = [ interval * 2, MAX_POLL_INTERVAL ].min
        end
      end
    end

    def run_wait(step_data, step_run_id)
      seconds = start_wait(step_run_id, step_data["kind_config"])["seconds"]
      return recover_from_step_failure(step_data, step_run_id) unless seconds.is_a?(Numeric)

      # Polls rather than sleeps: a cancel whose signal was lost is seen only in the database.
      await_decision_until(step_run_id, Temporalio::Workflow.now + seconds)
      return :cancelled if @cancelled
      return :skipped if @step_decisions[step_run_id] == :skipped

      case finish_wait(step_run_id)["state"]
      when "skipped" then :skipped
      when "cancelled" then :cancelled
      when "failed" then recover_from_step_failure(step_data, step_run_id)
      else :completed
      end
    end

    def run_action(step_data, step_run_id)
      (@control_step_run_ids ||= []) << step_run_id
      started = start_action(step_data, step_run_id)
      return action_outcome(step_data, step_run_id, started["outcome"]) unless started["mode"] == "async"

      tool_result_id = started["tool_result_id"]
      await_action(step_run_id, tool_result_id, Temporalio::Workflow.now + started["deadline_seconds"])
      stopped = action_stopped(step_run_id)
      finished = finish_action(step_data, step_run_id, tool_result_id, stopped)
      stopped ? stopped.to_sym : action_outcome(step_data, step_run_id, finished["outcome"])
    end

    def action_stopped(step_run_id)
      return "cancelled" if @cancelled

      "skipped" if @step_decisions[step_run_id] == :skipped
    end

    def action_outcome(step_data, step_run_id, outcome)
      case outcome
      when "completed" then :completed
      when "skipped" then :skipped
      when "cancelled" then :cancelled
      when "failed" then recover_from_step_failure(step_data, step_run_id)
      else raise Temporalio::Error::ApplicationError.new("Unknown action outcome: #{outcome.inspect}", non_retryable: true)
      end
    end

    # Nothing signals when a Wrapper finishes, so every poll reads its result.
    def await_action(step_run_id, tool_result_id, deadline)
      interval = INITIAL_POLL_INTERVAL
      loop do
        refresh_session_decisions([ step_run_id ])
        return if action_stopped(step_run_id)
        return if action_status(tool_result_id)["state"] != "processing"

        left = deadline - Temporalio::Workflow.now
        return if left <= 0

        begin
          Temporalio::Workflow.timeout([ interval, left ].min) do
            Temporalio::Workflow.wait_condition { action_stopped(step_run_id) }
          end
          return
        rescue Timeout::Error
          interval = [ interval * 2, MAX_POLL_INTERVAL ].min
        end
      end
    end

    # The config the run recorded at its start, not the step's current one: an
    # edit to the step mid-run must not change, or break, a step already running.
    def open_approval(step_run_id, kind_config)
      execute_activity(activities.workflow_open_approval_activity,
        { step_run_id: step_run_id, kind_config: kind_config }, start_to_close_timeout: 30)
    end

    def expire_approval(step_run_id, kind_config)
      execute_activity(activities.workflow_expire_approval_activity,
        { step_run_id: step_run_id, kind_config: kind_config }, start_to_close_timeout: 30)
    end

    def start_wait(step_run_id, kind_config)
      execute_activity(activities.workflow_start_wait_activity,
        { step_run_id: step_run_id, kind_config: kind_config }, start_to_close_timeout: 30)
    end

    def finish_wait(step_run_id)
      execute_activity(activities.workflow_finish_wait_activity,
        { step_run_id: step_run_id }, start_to_close_timeout: 30)
    end

    # A side-effecting start gets one retry: the activity sees its first attempt
    # and fails the step as outcome unknown instead of sending again. The timeout
    # outlasts MCP::ToolCaller's handshake, its 10 s open and its 120 s read.
    def start_action(step_data, step_run_id)
      read = step_data["kind_config"].to_h["effect"] == "read"
      retry_policy = read ? default_retry_policy : Temporalio::RetryPolicy.new(max_attempts: 2)
      execute_activity(activities.workflow_start_action_activity,
        { step_run_id: step_run_id, kind_config: step_data["kind_config"],
          depends_on_step_ids: step_data["depends_on_step_ids"] },
        start_to_close_timeout: 300, retry_policy: retry_policy)
    end

    def action_status(tool_result_id)
      execute_activity(activities.workflow_action_status_activity,
        { tool_result_id: tool_result_id }, start_to_close_timeout: 30)
    end

    def finish_action(step_data, step_run_id, tool_result_id, stopped)
      execute_activity(activities.workflow_finish_action_activity,
        { step_run_id: step_run_id, kind_config: step_data["kind_config"], tool_result_id: tool_result_id,
          stopped: stopped },
        start_to_close_timeout: 60)
    end

    def wait_for_all_parallel(pending, results, steps_by_id)
      until pending.empty? || @cancelled
        await_session_change(pending.values) do
          @cancelled || pending.values.any? { |sr_id| @step_decisions[sr_id] }
        end
        break if @cancelled

        pending.each do |step_id, sr_id|
          decision = @step_decisions[sr_id]
          next unless decision

          outcome = if %i[skipped retried cancelled].include?(decision)
            decision
          else
            result = complete_step(sr_id)
            result == :failed ? recover_from_step_completion_failure(steps_by_id[step_id], sr_id, result) : result
          end
          results[step_id] = outcome
        end
        pending.reject! { |step_id, _| results.key?(step_id) }
      end
      results
    end

    def wait_for_signal(step_run_id)
      await_session_change([ step_run_id ]) { @step_decisions[step_run_id] || @cancelled }
    end

    def wait_for_interactive_decision(step_data, step_run_id)
      @current_interactive_step_run_id = step_run_id
      wait_for_signal(step_run_id)
      @current_interactive_step_run_id = nil
      return :cancelled if @cancelled

      case @step_decisions[step_run_id]
      when :completed
        outcome = complete_step(step_run_id)
        outcome == :failed ? recover_from_step_completion_failure(step_data, step_run_id, outcome) : outcome
      when :skipped then :skipped
      when :retried then execute_step(step_data)
      else :cancelled
      end
    end

    # Read durable state, then sleep until something signals or the backoff
    # window expires — whichever comes first. A signal resets the backoff, so an
    # active run stays responsive while an idle one goes quiet.
    def await_session_change(ids, &ready)
      interval = INITIAL_POLL_INTERVAL
      loop do
        @session_wake = false
        refresh_session_decisions(ids)
        return if ready.call

        begin
          Temporalio::Workflow.timeout(interval) do
            Temporalio::Workflow.wait_condition { ready.call || @session_wake }
          end
          interval = INITIAL_POLL_INTERVAL
        rescue Timeout::Error
          interval = [ interval * 2, MAX_POLL_INTERVAL ].min
        end
      end
    end

    def refresh_session_decisions(ids)
      result = execute_activity(activities.workflow_step_session_status_activity,
        { workflow_run_id: @workflow_run_id, step_run_ids: ids }, start_to_close_timeout: 30)
      @cancelled ||= result["cancelled"]
      result["sessions"].each do |id, status|
        if status["state"] == "cancelled" || status["step_state"] == "cancelled"
          @cancelled = true
          @step_decisions[id.to_i] = :cancelled
        elsif status["step_state"] == "skipped" && decisions_read_from_step_state?
          # Skip and Approve are written to the step before they are signalled,
          # so a signal that never arrives costs one poll, not the run.
          @step_decisions[id.to_i] ||= :skipped
        elsif status["state"].nil? && status["step_state"] == "failed" && control_step_run?(id.to_i)
          @step_decisions[id.to_i] ||= :rejected
        elsif %w[finished failed].include?(status["state"]) ||
              (status["step_state"] == "completed" && decisions_read_from_step_state?)
          @step_decisions[id.to_i] ||= :completed
        end
      end
    end

    def control_step_run?(step_run_id)
      @control_step_run_ids&.include?(step_run_id)
    end

    # Code without this patch kept polling past a Skip or Approve whose signal
    # was lost, and its histories must replay that way.
    def decisions_read_from_step_state?
      Temporalio::Workflow.patched("step-state-decides-without-signal")
    end

    # Every wait here reads the durable state, so a decision that arrived while
    # the launch was still returning is never cleared.
    def keep_signals_delivered_during_launch? = true
  end
end

# frozen_string_literal: true

require "test_helper"

module UsageStatistics
  class AccumulatorTest < ActiveSupport::TestCase
    setup do
      @user = create(:user)
      @session = create(:terminal_session, user: @user)
    end

    def event(model: "claude-sonnet-5", input: 0, output: 0, cache_write: 0, cache_read: 0, cents: 0.0, timestamp: "1")
      {
        "model" => model,
        "timestamp" => timestamp,
        "tokenUsage" => {
          "inputTokens" => input,
          "outputTokens" => output,
          "cacheWriteTokens" => cache_write,
          "cacheReadTokens" => cache_read,
          "totalCents" => cents
        }
      }
    end

    test "returns accepted and writes nothing when the batch is empty" do
      result = Accumulator.record(terminal_session: @session, events: [])

      assert_equal :accepted, result
      assert_nil @session.reload.usage_statistic
    end

    test "creates the row from the first batch" do
      result = Accumulator.record(
        terminal_session: @session,
        events: [ event(input: 100, output: 20, cache_read: 5, cache_write: 3, cents: 1.5) ]
      )

      assert_equal :ok, result
      stat = @session.reload.usage_statistic
      assert_equal 100, stat.input_tokens
      assert_equal 20, stat.output_tokens
      assert_equal 3, stat.cache_write_tokens
      assert_equal 5, stat.cache_read_tokens
      assert_equal 1, stat.events_count
      assert_equal "otlp", stat.source
      assert_equal [ "claude-sonnet-5" ], stat.models
    end

    test "adds each further batch to the running totals instead of recomputing them" do
      3.times do |i|
        Accumulator.record(terminal_session: @session, events: [ event(input: 10, cents: 0.5, timestamp: i.to_s) ])
      end

      stat = @session.reload.usage_statistic
      assert_equal 30, stat.input_tokens
      assert_equal 3, stat.events_count
      assert_equal 3, stat.events_data.size
      assert_in_delta 1.5, stat.total_cents_precise.to_f, 0.0001
    end

    test "appends events in arrival order without reading the accumulated blob" do
      Accumulator.record(terminal_session: @session, events: [ event(input: 1, timestamp: "first") ])
      Accumulator.record(
        terminal_session: @session,
        events: [ event(input: 2, timestamp: "second"), event(input: 3, timestamp: "third") ]
      )

      timestamps = @session.reload.usage_statistic.events_data.map { |e| e["timestamp"] }
      assert_equal %w[first second third], timestamps
    end

    test "rounds cost up from the accumulated precise total, not per batch" do
      # Four batches of 0.4 cents. Rounding each one up would bill 4; the total is 1.6 -> 2.
      4.times { Accumulator.record(terminal_session: @session, events: [ event(cents: 0.4) ]) }

      stat = @session.reload.usage_statistic
      assert_in_delta 1.6, stat.total_cents_precise.to_f, 0.0001
      assert_equal 2, stat.cost_cents
    end

    test "keeps models as a distinct set across batches" do
      Accumulator.record(terminal_session: @session, events: [ event(model: "claude-sonnet-5") ])
      Accumulator.record(terminal_session: @session, events: [ event(model: "claude-haiku-4-5") ])
      Accumulator.record(terminal_session: @session, events: [ event(model: "claude-sonnet-5") ])

      assert_equal %w[claude-haiku-4-5 claude-sonnet-5], @session.reload.usage_statistic.models
    end

    test "ignores events that carry no model rather than storing a blank one" do
      Accumulator.record(terminal_session: @session, events: [ event(model: nil, input: 7) ])

      stat = @session.reload.usage_statistic
      assert_empty stat.models
      assert_equal 7, stat.input_tokens
    end

    test "folds a multi-event batch in one write" do
      assert_difference -> { UsageStatistic.count }, 1 do
        Accumulator.record(
          terminal_session: @session,
          events: [ event(input: 1), event(input: 2), event(input: 4) ]
        )
      end

      stat = @session.reload.usage_statistic
      assert_equal 7, stat.input_tokens
      assert_equal 3, stat.events_count
    end

    test "keeps each session's totals separate" do
      other = create(:terminal_session, user: @user)

      Accumulator.record(terminal_session: @session, events: [ event(input: 10) ])
      Accumulator.record(terminal_session: other, events: [ event(input: 99) ])

      assert_equal 10, @session.reload.usage_statistic.input_tokens
      assert_equal 99, other.reload.usage_statistic.input_tokens
    end

    test "records the source it is given" do
      Accumulator.record(terminal_session: @session, events: [ event(input: 1) ], source: "mitm")

      assert_equal "mitm", @session.reload.usage_statistic.source
    end
  end

    # The fast path to Budgets::Enforcer: a job only on a crossing, and never a failure of
    # the telemetry write.
    class BudgetWatchTest < ActiveJob::TestCase
      setup do
        company = create(:company)
        @user = create(:user, :admin, company: company)
        @project = create(:project, company: company, owner: @user)
        @workflow = create(:workflow, scope: @project)
        @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
      end

      def event(cents) = { "model" => "m", "tokenUsage" => { "totalCents" => cents } }

      def step_session(cap: nil)
        session = create(:terminal_session, user: @user, project: @project, session_type: "workflow_step", state: "ready")
        create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow), terminal_session: session).update_columns(budget_cents: cap)
        session
      end

      test "enqueues the enforcer when a step session reaches its step cap" do
        session = step_session(cap: 100)

        assert_enqueued_with(job: Budgets::EnforceJob, args: [ session.id, @run.id ]) do
          Accumulator.record(terminal_session: session, events: [ event(100.0) ])
        end
      end

      test "enqueues nothing below the step cap" do
        session = step_session(cap: 100)

        assert_no_enqueued_jobs { Accumulator.record(terminal_session: session, events: [ event(99.0) ]) }
      end

      test "enqueues for a run cap only once the run has spent it" do
        @run.update!(budget_cents: 500)
        session = step_session

        assert_no_enqueued_jobs do
          5.times { Accumulator.record(terminal_session: session, events: [ event(50.0) ]) }
        end
        assert_enqueued_jobs 1, only: Budgets::EnforceJob do
          Accumulator.record(terminal_session: session, events: [ event(250.0) ])
        end
      end

      test "enqueues nothing for a step without any cap" do
        session = step_session

        assert_no_enqueued_jobs { Accumulator.record(terminal_session: session, events: [ event(5000.0) ]) }
      end

      test "a session that is not a workflow step costs no budget query" do
        session = create(:terminal_session, :agent_session, user: @user, project: @project)

        assert_queries_match(/step_runs/, count: 0) do
          assert_no_enqueued_jobs { Accumulator.record(terminal_session: session, events: [ event(5000.0) ]) }
        end
      end

      test "a workflow step costs one budget query" do
        session = step_session(cap: 100)

        assert_queries_match(/FROM "step_runs"/, count: 1) do
          Accumulator.record(terminal_session: session, events: [ event(1.0) ])
        end
      end

      test "an error in the watch does not fail the write" do
        session = step_session(cap: 1)
        Budgets::EnforceJob.stubs(:perform_later).raises(StandardError, "queue down")
        Rails.logger.expects(:warn).with(regexp_matches(/Budgets::Watch.*queue down/))

        assert_equal :ok, Accumulator.record(terminal_session: session, events: [ event(50.0) ])
        assert_equal 50, session.reload.usage_statistic.cost_cents
      end
    end
end

# frozen_string_literal: true

require "test_helper"

class Budgets::ExceededTest < ActiveSupport::TestCase
  test "a refused call with no estimate reads as spent of cap" do
    assert_equal "Budget exceeded: this step has spent $1.00 of its $1.00 cap, so the call was not sent.",
                 exceeded(:step, 100, 100, 0).message(:refused_action)
    assert_equal "Budget exceeded: this run has spent $1.30 of its $1.00 cap, so the call was not sent.",
                 exceeded(:run, 100, 130, 0).message(:refused_action)
  end

  test "running message names the scope, the spend and the cap" do
    assert_equal "Budget exceeded: this step spent $1.02 of its $1.00 cap.",
                 exceeded(:step, 100, 102).message(:running)
    assert_equal "Budget exceeded: this run spent $5.10 of its $5.00 cap.",
                 exceeded(:run, 500, 510).message(:running)
  end

  test "refused start message says the step was not started again" do
    assert_equal "Budget exceeded: this step has spent $1.02 of its $1.00 cap, so it was not started again.",
                 exceeded(:step, 100, 102).message(:refused_start)
    assert_equal "Budget exceeded: this run has spent $5.00 of its $5.00 cap, so it was not started again.",
                 exceeded(:run, 500, 500).message(:refused_start)
  end

  test "refused action message gives the estimate and what is left" do
    assert_equal "Budget exceeded: this call is estimated at $0.40 and the step has $0.25 left of its $1.00 cap, so it was not sent.",
                 exceeded(:step, 100, 75, 40).message(:refused_action)
    assert_equal "Budget exceeded: this call is estimated at $0.40 and the run has $0.00 left of its $1.00 cap, so it was not sent.",
                 exceeded(:run, 100, 130, 40).message(:refused_action)
  end

  test "money is exact dollars and cents, with no abbreviation from $1000" do
    assert_equal "Budget exceeded: this run spent $1000.49 of its $1000.00 cap.",
                 exceeded(:run, 100_000, 100_049).message(:running)
    assert_equal "Budget exceeded: this step spent $100000.00 of its $10000.00 cap.",
                 exceeded(:step, 1_000_000, 10_000_000).message(:running)
  end

  test "an unknown kind is refused" do
    assert_raises(ArgumentError) { exceeded(:step, 100, 102).message(:other) }
  end

  test "to_marker is the budget_stop hash" do
    freeze_time do
      assert_equal({ "scope" => "step", "cap_cents" => 100, "spent_cents" => 102, "at" => Time.current.iso8601 },
                   exceeded(:step, 100, 102).to_marker)
    end
  end

  private

  def exceeded(scope, cap, spent, estimate = 0)
    Budgets::Exceeded.new(scope: scope, cap_cents: cap, spent_cents: spent, estimate_cents: estimate)
  end
end

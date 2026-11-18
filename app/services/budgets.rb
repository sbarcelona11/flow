# frozen_string_literal: true

# Spend caps on steps and workflows, in whole US cents (docs/superpowers/plans/2026-11-21-automations-p3-budget-cap.md).
module Budgets
  MAX_CENTS = 1_000_000

  # Exact dollars and cents ("$1.02", "$1000.49"). The UI's formatCostCents abbreviates from $1000, which
  # would make a stop message read "spent $1.0k of its $1.0k cap".
  def self.format_cents(cents)
    cents = cents.to_i
    format("$%d.%02d", cents / 100, cents % 100)
  end
end

# frozen_string_literal: true

# Spend caps on steps and workflows, in whole US cents (docs/superpowers/plans/2026-11-21-automations-p3-budget-cap.md).
module Budgets
  MAX_CENTS = 1_000_000

  # Same text as the frontend's formatCostCents: "$1.02", and "$1.5k" from $1000.
  def self.format_cents(cents)
    dollars = cents.to_i / 100.0
    return format("$%.1fk", dollars / 1000) if dollars >= 1000

    format("$%.2f", dollars)
  end
end

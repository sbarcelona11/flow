# frozen_string_literal: true

# A nullable spend cap in whole cents. Only nil means "no cap": a value the integer type
# cannot read (Infinity, NaN, "", false, an array) is refused, not cast to nil.
module BudgetCapped
  extend ActiveSupport::Concern

  included do
    validates :budget_cents, numericality: { only_integer: true, in: 1..Budgets::MAX_CENTS }, allow_nil: true
    validate :budget_cents_is_readable
  end

  private

  def budget_cents_is_readable
    return unless budget_cents.nil? && !budget_cents_before_type_cast.nil?

    errors.add(:budget_cents, "must be an integer")
  end
end

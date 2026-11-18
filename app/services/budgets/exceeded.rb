# frozen_string_literal: true

module Budgets
  # A cap that was reached. +scope+ is :step or :run, +estimate_cents+ is the
  # cost of the call being refused (0 for a running session).
  Exceeded = Data.define(:scope, :cap_cents, :spent_cents, :estimate_cents) do
    def message(kind)
      cap = Budgets.format_cents(cap_cents)
      spent = Budgets.format_cents(spent_cents)

      "Budget exceeded: " + case kind
      when :running then "this #{scope} spent #{spent} of its #{cap} cap."
      when :refused_start then "this #{scope} has spent #{spent} of its #{cap} cap, so it was not started again."
      when :refused_action
        if estimate_cents.to_i.zero?
          "this #{scope} has spent #{spent} of its #{cap} cap, so the call was not sent."
        else
          left = Budgets.format_cents([ cap_cents - spent_cents, 0 ].max)
          "this call is estimated at #{Budgets.format_cents(estimate_cents)} and the #{scope} has #{left} left of its #{cap} cap, so it was not sent."
        end
      else raise ArgumentError, "unknown budget message kind: #{kind.inspect}"
      end
    end

    def to_marker
      { "scope" => scope.to_s, "cap_cents" => cap_cents, "spent_cents" => spent_cents, "at" => Time.current.iso8601 }
    end
  end
end

# frozen_string_literal: true

module Actions
  # What an action may do to the outside world, strictest last
  # (Step::ACTION_EFFECTS). A step may declare a stricter effect than its tool's
  # own, never a lower one (docs/design/visual-block-builder.md D4, §3.1).
  module Effect
    APPROVAL_REQUIRED = %w[send irreversible].freeze

    module_function

    # The rule of app/frontend/shared/resources/mcp-servers/toolEffect.ts.
    def base_for_annotations(annotations)
      annotations = annotations.to_h
      return "read" if annotations["readOnlyHint"] == true
      return "irreversible" if annotations["destructiveHint"] == true

      "write"
    end

    def base_for_wrapper = "write"

    def base_for_operation(operation) = operation.effect

    def at_least?(effect, base)
      rank = Step::ACTION_EFFECTS.index(effect)
      floor = Step::ACTION_EFFECTS.index(base)
      !rank.nil? && !floor.nil? && rank >= floor
    end

    def needs_approval?(effect) = APPROVAL_REQUIRED.include?(effect)
  end
end

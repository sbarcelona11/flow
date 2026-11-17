# frozen_string_literal: true

class AddOneSideEffectPerStepRunToActionCalls < ActiveRecord::Migration[8.1]
  def change
    add_index :action_calls, :step_run_id, unique: true, where: "effect <> 'read'",
                                           name: "index_action_calls_on_step_run_id_side_effect"
  end
end

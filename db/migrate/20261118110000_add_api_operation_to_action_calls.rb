# frozen_string_literal: true

class AddApiOperationToActionCalls < ActiveRecord::Migration[8.1]
  def change
    add_reference :action_calls, :api_operation, foreign_key: { on_delete: :nullify }
  end
end

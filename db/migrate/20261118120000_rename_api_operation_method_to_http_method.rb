# frozen_string_literal: true

class RenameApiOperationMethodToHttpMethod < ActiveRecord::Migration[8.1]
  def change
    rename_column :api_operations, :method, :http_method
  end
end

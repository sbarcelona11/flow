# frozen_string_literal: true

FactoryBot.define do
  factory :api_operation do
    api_connector { association :api_connector, strategy: :create }
    sequence(:name) { |n| "operation_#{n}" }
    add_attribute(:method) { "GET" }
    path { "/things" }
    effect { "read" }
    input_schema { {} }

    trait :with_path_param do
      path { "/things/{id}" }
      input_schema do
        { "type" => "object",
          "properties" => { "path" => { "type" => "object", "properties" => { "id" => { "type" => "string" } },
                                        "required" => [ "id" ] } } }
      end
    end
  end
end

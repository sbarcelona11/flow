# frozen_string_literal: true

FactoryBot.define do
  factory :api_connector do
    sequence(:name) { |n| "api-connector-#{n}" }
    base_url { "https://api.example.com/v1" }
    auth_type { "none" }
    scope factory: %i[project standalone]

    trait :bearer do
      auth_type { "bearer" }
      auth_config { { "config_item_name" => "EXAMPLE_TOKEN" } }
    end
  end
end

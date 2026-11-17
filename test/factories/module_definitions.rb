# frozen_string_literal: true

FactoryBot.define do
  factory :module_definition do
    scope factory: %i[project standalone]
    sequence(:slug) { |n| "module-#{n}" }
    namespace { "acme" }
    kind { "type" }
    version { 1 }
    manifest do
      { "kind" => kind, "namespace" => namespace, "slug" => slug, "version" => version, "label" => "Module",
        "schema" => { "type" => "string" } }
    end

    trait :capability do
      kind { "capability" }
      manifest do
        { "kind" => "capability", "namespace" => namespace, "slug" => slug, "version" => version, "label" => "Capability",
          "input" => "aixle/string@1", "output" => "aixle/string@1" }
      end
    end

    trait :control_block do
      kind { "block" }
      manifest do
        { "kind" => "block", "namespace" => namespace, "slug" => slug, "version" => version, "label" => "Approve",
          "executor" => "control", "control" => "approval",
          "ports" => { "in" => { "subject" => "aixle/string@1" }, "out" => { "decision" => "aixle/string@1" } } }
      end
    end
  end
end

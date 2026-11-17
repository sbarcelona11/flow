# frozen_string_literal: true

FactoryBot.define do
  factory :mcp_server do
    sequence(:name) { |n| "mcp-server-#{n}" }
    kind { :custom }
    transport { :sse }
    url { "https://mcp.example.com/v1" }
    description { "Test MCP server" }
    enabled { true }

    # Custom servers are Project-scoped only.
    scope factory: %i[project standalone]

    # == Kind Traits ==

    trait :internal do
      kind { :internal }
      scope { nil }
      url { nil }
    end

    trait :custom do
      kind { :custom }
      scope factory: %i[project standalone]
    end

    # == Common Configurations ==

    trait :with_headers do
      headers { { "Authorization" => "Bearer test-token" } }
    end

    trait :disabled do
      enabled { false }
    end

    # A baseline as MCP::ToolListProbe stores it, schemas and annotations included.
    trait :with_tool_schemas do
      transient do
        snapshot_tools { [ { "name" => "search" } ] }
      end
      tool_snapshot_at { Time.current }
      tool_snapshot do
        entries = snapshot_tools.map do |tool|
          schema = tool.fetch("input_schema", { "type" => "object" })
          annotations = tool.fetch("annotations", {})
          description = tool.fetch("description", "#{tool['name']} tool")
          { "name" => tool["name"], "description" => description,
            "description_digest" => Digest::SHA256.hexdigest(description),
            "schema_digest" => Digest::SHA256.hexdigest(schema.to_json),
            "annotations_digest" => Digest::SHA256.hexdigest(annotations.to_json),
            "input_schema" => schema, "output_schema" => nil, "annotations" => annotations }
        end
        { "tools" => entries, "captured_at" => Time.current.iso8601 }
      end
    end

    trait :stdio_transport do
      transport { :stdio }
      url { nil }
    end
  end
end

# frozen_string_literal: true

require "test_helper"

class ApiOperationTest < ActiveSupport::TestCase
  def build_operation(**attrs)
    build(:api_operation, **attrs)
  end

  test "a valid operation saves" do
    assert build_operation.save
  end

  test "an operation path can't carry a host, .. or a query" do
    [ "https://evil.example/x", "//evil.example/x", "things", "/a/../b", "/a//b", "/a?x=1", "/a#frag",
      "/a/%2e%2e/b" ].each do |path|
      operation = build_operation(path: path)
      assert_not operation.valid?, "#{path} accepted"
      assert operation.errors[:path].any?
    end
  end

  test "a POST operation can't be read" do
    operation = build_operation(method: "POST", effect: "read")

    assert_not operation.valid?
    assert_includes operation.errors[:effect], "can't be lower than write for a POST operation"
    assert_equal "write", operation.minimum_effect
    assert build_operation(method: "POST", effect: "write").valid?
    assert build_operation(method: "DELETE", effect: "irreversible").valid?
    assert_equal "read", build_operation.minimum_effect
  end

  test "a path placeholder must be a required path parameter" do
    assert_not build_operation(path: "/things/{id}").valid?

    optional = { "type" => "object", "properties" => { "path" => { "type" => "object",
                 "properties" => { "id" => { "type" => "string" } } } } }
    operation = build_operation(path: "/things/{id}", input_schema: optional)
    assert_not operation.valid?
    assert_match(/\{id\}/, operation.errors[:path].first)

    assert build(:api_operation, :with_path_param).valid?
  end

  test "names are unique per connector" do
    first = create(:api_operation, name: "list_things")

    assert_not build_operation(api_connector: first.api_connector, name: "list_things").valid?
    assert build_operation(name: "list_things").valid?
  end

  test "the name format is enforced" do
    %w[ListThings 1things list-things].each { |name| assert_not build_operation(name: name).valid?, name }
  end

  test "the input schema is held to the tool schema hygiene" do
    assert_not build_operation(input_schema: { "$ref" => "#/x" }).valid?
    assert_not build_operation(input_schema: { "type" => "bogus" }).valid?
    deep = { "type" => "object" }
    14.times { deep = { "type" => "object", "properties" => { "body" => deep } } }
    assert_not build_operation(input_schema: deep).valid?
  end

  test "arguments are grouped as path, query and body" do
    odd = { "type" => "object", "properties" => { "headers" => { "type" => "object" } } }
    assert_not build_operation(input_schema: odd).valid?

    scalar = { "type" => "object", "properties" => { "query" => { "type" => "string" } } }
    assert_not build_operation(input_schema: scalar).valid?
  end

  test "an unknown method is refused" do
    assert_not build_operation(method: "TRACE").valid?
  end
end

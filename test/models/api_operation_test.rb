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
      "/a/%2e%2e/b", "/%2E%2E/admin", "/.%2e/x", "/a\\b", "/a%2Fb", "/a%5cb", "/a b", "/./x", "/ü" ].each do |path|
      operation = build_operation(path: path)
      assert_not operation.valid?, "#{path} accepted"
      assert operation.errors[:path].any?
    end
  end

  test "a POST operation can't be read" do
    operation = build_operation(http_method: "POST", effect: "read")

    assert_not operation.valid?
    assert_includes operation.errors[:effect], "can't be lower than write for a POST operation"
    assert_equal "write", operation.minimum_effect
    assert build_operation(http_method: "POST", effect: "write").valid?
    assert build_operation(http_method: "DELETE", effect: "irreversible").valid?
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
    assert_not build_operation(http_method: "TRACE").valid?
  end

  test "a cost per call is nil or a whole number of cents from 0 to Budgets::MAX_CENTS" do
    [ nil, 0, 1, 40, Budgets::MAX_CENTS ].each do |cents|
      assert build_operation(cost_cents: cents).valid?, cents.inspect
    end
    [ -1, Budgets::MAX_CENTS + 1, 1.5, Float::INFINITY, Float::NAN, [ 5 ], {}, "", false, "abc", 1.0 ].each do |cents|
      operation = build_operation(cost_cents: cents)
      assert_not operation.valid?, cents.inspect
      assert operation.errors.key?(:cost_cents), cents.inspect
    end
  end

  test "the database refuses an enabled row that was never reviewed" do
    record = build_operation.tap(&:save!)

    assert_raises(ActiveRecord::CheckViolation) { record.update_columns(reviewed_at: nil, enabled: true) }
  end

  test "the database refuses an origin it does not know" do
    record = build_operation.tap(&:save!)

    assert_raises(ActiveRecord::CheckViolation) { record.update_columns(origin: "robot") }
  end

  test "the database refuses to enable a rejected row" do
    record = build_operation(origin: "builder", reviewed_at: nil, enabled: false).tap(&:save!)

    assert_raises(ActiveRecord::CheckViolation) { record.update_columns(rejected_at: Time.current, enabled: true, reviewed_at: Time.current) }
  end

  test "a row saved with no stamp and no validation fails closed at the database" do
    record = build_operation
    record.reviewed_at = nil

    assert_raises(ActiveRecord::CheckViolation) { record.save!(validate: false) }
  end

  test "an enabled row with no review stamp is a readable validation error" do
    record = build_operation
    record.reviewed_at = nil

    assert_not record.valid?
    assert_includes record.errors[:enabled], "needs a review before it can be enabled"
  end

  test "a row with no origin is refused" do
    record = build_operation
    record.origin = nil

    assert_not record.valid?
    assert record.errors[:origin].any?
  end

  test "an unknown origin is refused" do
    record = build_operation
    record.origin = "robot"

    assert_not record.valid?
    assert record.errors[:origin].any?
  end

  test "a proposed row saves disabled and unreviewed whatever enabled it was given" do
    record = build_operation(origin: "builder", reviewed_at: nil, enabled: false)
    record.enabled = true

    assert record.save, record.errors.full_messages.to_sentence
    assert_equal false, record.reload.enabled # rubocop:disable Minitest/RefuteFalse
    assert_nil record.reviewed_at
    assert_equal "waiting", record.review_state
    assert_includes ApiOperation.awaiting_review, record
  end

  test "an update cannot enable an unreviewed row" do
    record = build_operation(origin: "builder", reviewed_at: nil, enabled: false).tap(&:save!)

    assert_not record.update(enabled: true)
    assert_includes record.errors[:enabled], "needs a review before it can be enabled"
    assert_equal false, record.reload.enabled # rubocop:disable Minitest/RefuteFalse
  end

  test "a rejected row leaves the review queue and cannot be enabled" do
    record = build_operation(origin: "builder", reviewed_at: nil, enabled: false).tap(&:save!)
    record.update!(rejected_at: Time.current)

    assert_equal "rejected", record.review_state
    assert_not_includes ApiOperation.awaiting_review, record
    record.assign_attributes(enabled: true, reviewed_at: Time.current)
    assert_not record.valid?
  end
end

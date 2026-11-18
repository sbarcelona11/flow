# frozen_string_literal: true

require "test_helper"

class Authoring::ReviewTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, company: @company)
    @project = create(:project, company: @company, owner: @user)
  end

  def propose(*factory, **attrs)
    record = build(*factory, **attrs)
    Authoring::Review.propose!(record, user: @user, origin: "builder", session: Struct.new(:id).new(42))
  end

  def connector_with_operation
    connector = propose(:api_connector, scope: @project)
    operation = propose(:api_operation, api_connector: connector)
    [ connector, operation ]
  end

  test "stamp_web! marks a record as created and reviewed by the person" do
    connector = build(:api_connector, scope: @project)

    Authoring::Review.stamp_web!(connector, @user)

    assert_equal "web", connector.origin
    assert_equal @user, connector.created_by
    assert_equal @user, connector.reviewed_by
    assert_not_nil connector.reviewed_at
    assert connector.save, connector.errors.full_messages.to_sentence
  end

  test "propose! saves a disabled unreviewed row and audits it without values" do
    connector = nil
    assert_difference -> { Audit.where(action: "authoring.proposed").count }, 1 do
      connector = propose(:api_connector, :bearer, scope: @project, enabled: true)
    end

    assert_equal "builder", connector.origin
    assert_equal @user, connector.created_by
    assert_equal 42, connector.origin_session_id
    assert_equal false, connector.reload.enabled # rubocop:disable Minitest/RefuteFalse
    assert_nil connector.reviewed_at

    audit = Audit.where(action: "authoring.proposed").last
    assert_equal connector, audit.auditable
    assert_equal @user, audit.user
    assert_equal @project, audit.associated
    changes = audit.audited_changes
    assert_equal "ApiConnector", changes["type"]
    assert_equal "builder", changes["origin"]
    assert_equal "waiting", changes["status"]
    assert_equal 42, changes["session_id"]
    assert_match(/\A\h{64}\z/, changes["digest"])
    assert_no_match(/EXAMPLE_TOKEN/, changes.to_s)
  end

  test "propose! refuses the web origin" do
    assert_raises(ArgumentError) do
      Authoring::Review.propose!(build(:api_connector, scope: @project), user: @user, origin: "web")
    end
  end

  test "approve! stamps, enables and audits every record in one go" do
    connector, operation = connector_with_operation

    assert_difference -> { Audit.where(action: "authoring.approved").count }, 2 do
      Authoring::Review.approve!([ connector, operation ], user: @user)
    end

    [ connector, operation ].each do |record|
      record.reload
      assert record.enabled
      assert_equal @user, record.reviewed_by
      assert_not_nil record.reviewed_at
      assert_equal "reviewed", record.review_state
      assert_equal "builder", record.origin
    end
  end

  test "a failure in the batch leaves no record stamped" do
    connector, operation = connector_with_operation
    operation.update_columns(path: "not a path")

    assert_no_difference -> { Audit.where(action: "authoring.approved").count } do
      assert_raises(ActiveRecord::RecordInvalid) { Authoring::Review.approve!([ connector, operation ], user: @user) }
    end

    assert_nil connector.reload.reviewed_at
    assert_not connector.enabled
    assert_nil operation.reload.reviewed_at
  end

  test "approve! needs a person and a waiting record" do
    connector, = connector_with_operation

    assert_raises(ArgumentError) { Authoring::Review.approve!([ connector ], user: nil) }
    assert_raises(ArgumentError) { Authoring::Review.approve!([ connector ], user: "token") }

    Authoring::Review.approve!([ connector ], user: @user)
    assert_raises(Authoring::Review::AlreadyReviewed) { Authoring::Review.approve!([ connector ], user: @user) }
  end

  test "approve! refuses an archived record" do
    connector, = connector_with_operation
    connector.archive!

    assert_raises(Authoring::Review::Archived) { Authoring::Review.approve!([ connector ], user: @user) }
  end

  test "reject! archives a connector or module and disables an operation, with audit rows" do
    connector, operation = connector_with_operation
    block = propose(:module_definition, :control_block, scope: @project)

    assert_difference -> { Audit.where(action: "authoring.rejected").count }, 3 do
      Authoring::Review.reject!([ connector, operation, block ], user: @user)
    end

    assert connector.reload.archived?
    assert_not operation.reload.enabled
    assert block.reload.archived?
    [ connector, operation, block ].each { |record| assert_nil record.reviewed_at }
  end

  test "reject! refuses a record that was already reviewed" do
    connector = create(:api_connector, scope: @project)

    assert_raises(Authoring::Review::AlreadyReviewed) { Authoring::Review.reject!([ connector ], user: @user) }
    assert_not connector.reload.archived?
  end

  test "approving a module does not make its manifest editable afterwards" do
    block = propose(:module_definition, :control_block, scope: @project)
    Authoring::Review.approve!([ block ], user: @user)

    assert_not block.reload.update(manifest: block.manifest.merge("label" => "Changed"))
  end
end

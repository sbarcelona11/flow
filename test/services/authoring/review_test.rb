# frozen_string_literal: true

require "test_helper"

class Authoring::ReviewTest < ActiveSupport::TestCase
  setup do
    @company = create(:company)
    @user = create(:user, company: @company)
    @project = create(:project, company: @company, owner: @user)
    @user_session = UserSession.start!(user: @user)
  end

  def propose(*factory, **attrs)
    record = build(*factory, **attrs)
    Authoring::Review.propose!(record, user: @user, origin: "builder", session: Struct.new(:id).new(42))
  end

  def connector_with_operation
    connector = propose(:api_connector, :proposed, scope: @project)
    operation = propose(:api_operation, :proposed, api_connector: connector)
    [ connector, operation ]
  end

  def digests(*records) = records.to_h { |record| [ record, Authoring::Review.digest_for(record) ] }

  def approve(*records, user_session: @user_session, project: @project, expected: digests(*records))
    Authoring::Review.approve!(records, user_session: user_session, project: project, expected_digests: expected)
  end

  def reject(*records, user_session: @user_session, project: @project)
    Authoring::Review.reject!(records, user_session: user_session, project: project)
  end

  test "stamp_web! marks a record as created and reviewed by the person" do
    connector = build(:api_connector, :proposed, scope: @project)

    Authoring::Review.stamp_web!(connector, @user)

    assert_equal "web", connector.origin
    assert_equal @user, connector.created_by
    assert_equal @user, connector.reviewed_by
    assert_not_nil connector.reviewed_at
    connector.enabled = true
    assert connector.save, connector.errors.full_messages.to_sentence
  end

  test "stamp_web! needs a real person" do
    connector = build(:api_connector, :proposed, scope: @project)

    assert_raises(ArgumentError) { Authoring::Review.stamp_web!(connector, nil) }
    assert_raises(ArgumentError) { Authoring::Review.stamp_web!(connector, "token") }
    assert_nil connector.reviewed_at
  end

  test "propose! saves a disabled unreviewed row and audits it without values" do
    connector = nil
    assert_difference -> { Audit.where(action: "authoring.proposed").count }, 1 do
      connector = propose(:api_connector, :proposed, :bearer, scope: @project)
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
    assert_equal [ "ApiConnector", "builder", "waiting", 42 ], changes.values_at("type", "origin", "status", "session_id")
    assert_equal Authoring::Review.digest_for(connector), changes["digest"]
    assert_no_match(/EXAMPLE_TOKEN/, changes.to_s)
  end

  test "propose! refuses the web origin and a record that already exists" do
    assert_raises(ArgumentError) do
      Authoring::Review.propose!(build(:api_connector, scope: @project), user: @user, origin: "web")
    end

    reviewed = create(:api_connector, scope: @project, base_url: "https://api.example.com/v1")
    reviewed.base_url = "https://evil.example.com"
    assert_raises(ArgumentError) { Authoring::Review.propose!(reviewed, user: @user, origin: "mcp") }
    assert_not_nil reviewed.reload.reviewed_at
    assert_equal "https://api.example.com/v1", reviewed.base_url

    block = create(:module_definition, scope: @project)
    assert_raises(ArgumentError) { Authoring::Review.propose!(block, user: @user, origin: "builder") }
    assert_not_nil block.reload.reviewed_at
  end

  test "propose! needs a person" do
    assert_raises(ArgumentError) do
      Authoring::Review.propose!(build(:api_connector, :proposed, scope: @project), user: nil, origin: "mcp")
    end
  end

  test "approve! stamps, enables and audits every record, with the digest the reviewer saw" do
    connector, operation = connector_with_operation
    seen = Authoring::Review.digest_for(connector)

    assert_difference -> { Audit.where(action: "authoring.approved").count }, 2 do
      approve(connector, operation)
    end

    [ connector, operation ].each do |record|
      record.reload
      assert record.enabled
      assert_equal @user, record.reviewed_by
      assert_equal "reviewed", record.review_state
      assert_equal "builder", record.origin
    end
    assert_equal seen, Audit.where(action: "authoring.approved", auditable: connector).last.audited_changes["digest"]
    assert_equal Audit.where(action: "authoring.proposed", auditable: connector).last.audited_changes["digest"], seen
  end

  test "the digest ignores the review state and covers the content" do
    connector, = connector_with_operation
    before = Authoring::Review.digest_for(connector)

    connector.update!(description: "changed")

    assert_not_equal before, Authoring::Review.digest_for(connector)
    Authoring::Review.send(:lock_and_check!, connector, @project)
    assert_equal Authoring::Review.digest_for(connector), Authoring::Review.digest_for(ApiConnector.find(connector.id))
  end

  test "approve! refuses content that changed after the reviewer saw it" do
    connector, = connector_with_operation
    seen = digests(connector)

    connector.update!(base_url: "https://evil.example.com")

    assert_no_difference -> { Audit.where(action: "authoring.approved").count } do
      assert_raises(Authoring::Review::ContentChanged) { approve(connector, expected: seen) }
    end
    assert_nil connector.reload.reviewed_at
    assert_not connector.enabled
  end

  test "approve! needs an expected digest for every record" do
    connector, = connector_with_operation

    assert_raises(ArgumentError) { approve(connector, expected: {}) }
  end

  test "a failure in the batch leaves no record stamped" do
    connector, operation = connector_with_operation
    expected = digests(connector, operation)
    operation.update_columns(path: "not a path")

    assert_no_difference -> { Audit.where(action: "authoring.approved").count } do
      assert_raises(Authoring::Review::ContentChanged, ActiveRecord::RecordInvalid) { approve(connector, operation, expected: expected) }
    end

    assert_nil connector.reload.reviewed_at
    assert_not connector.enabled
    assert_nil operation.reload.reviewed_at
  end

  test "approve! and reject! need a live signed-in web session, not a user" do
    connector, = connector_with_operation
    expected = digests(connector)
    revoked = UserSession.start!(user: @user).tap(&:revoke!)

    [ nil, @user, "token", revoked, UserSession.new(user: @user) ].each do |channel|
      assert_raises(ArgumentError) { approve(connector, user_session: channel, expected: expected) }
      assert_raises(ArgumentError) { reject(connector, user_session: channel) }
    end
    assert_nil connector.reload.reviewed_at
    assert_nil connector.rejected_at
  end

  test "approve! refuses a record that was already reviewed or is archived" do
    connector, = connector_with_operation
    approve(connector)

    assert_raises(Authoring::Review::AlreadyReviewed) { approve(connector) }

    other = propose(:api_connector, :proposed, scope: @project)
    other.update!(archived_at: Time.current)
    assert_raises(Authoring::Review::Archived) { approve(other) }
  end

  test "reject! gives a connector or module an end state and archives it, with audit rows" do
    connector, operation = connector_with_operation
    block = propose(:module_definition, :proposed, :control_block, scope: @project)

    assert_difference -> { Audit.where(action: "authoring.rejected").count }, 3 do
      reject(connector, operation, block)
    end

    assert connector.reload.archived?
    assert block.reload.archived?
    [ connector, operation, block ].each do |record|
      record.reload
      assert_equal "rejected", record.review_state
      assert_nil record.reviewed_at
      assert_equal @user, record.rejected_by
      assert_not record.enabled
      assert_not_includes record.class.awaiting_review, record
    end
  end

  test "a rejected operation can never be approved afterwards" do
    connector, operation = connector_with_operation
    reject(operation)

    assert_raises(Authoring::Review::Rejected) { approve(connector, operation, expected: digests(connector, operation)) }
    assert_nil connector.reload.reviewed_at
    assert_not operation.reload.enabled
  end

  test "reject! refuses a record that was already reviewed" do
    connector = create(:api_connector, scope: @project)

    assert_raises(Authoring::Review::AlreadyReviewed) { reject(connector) }
    assert_not connector.reload.archived?
  end

  test "two stale copies cannot both approve" do
    connector, = connector_with_operation
    first = ApiConnector.find(connector.id)
    second = ApiConnector.find(connector.id)
    expected = digests(connector)
    approve(first, expected: { first => expected[connector] })

    assert_raises(Authoring::Review::AlreadyReviewed) { approve(second, expected: { second => expected[connector] }) }
    assert_equal 1, Audit.where(action: "authoring.approved", auditable: connector).count
  end

  test "a stale copy cannot approve what another person rejected" do
    connector, = connector_with_operation
    stale = ApiConnector.find(connector.id)
    expected = { stale => Authoring::Review.digest_for(stale) }
    reject(connector)

    assert_raises(Authoring::Review::Rejected) { approve(stale, expected: expected) }
    assert_not connector.reload.enabled
  end

  test "a stale approved copy cannot be rejected" do
    connector, = connector_with_operation
    stale = ApiConnector.find(connector.id)
    approve(connector)

    assert_raises(Authoring::Review::AlreadyReviewed) { reject(stale) }
    assert connector.reload.enabled
  end

  test "records of another project are refused before anything is written" do
    connector, = connector_with_operation
    foreign = propose(:api_connector, :proposed, scope: create(:project, company: @company, owner: @user))

    assert_raises(Authoring::Review::WrongProject) { approve(connector, foreign) }
    assert_raises(Authoring::Review::WrongProject) { reject(connector, foreign) }
    assert_nil connector.reload.reviewed_at
    assert_nil connector.rejected_at
    assert_raises(ArgumentError) { approve(connector, project: nil) }
  end

  test "an operation cannot be approved before its connector" do
    connector, operation = connector_with_operation

    assert_raises(Authoring::Review::ConnectorNotReviewed) { approve(operation) }
    assert_nil operation.reload.reviewed_at

    approve(connector, operation)
    assert operation.reload.enabled
  end

  test "an operation under a rejected connector cannot be approved" do
    connector, operation = connector_with_operation
    reject(connector)

    assert_raises(Authoring::Review::ConnectorNotReviewed) { approve(operation) }
  end

  test "under impersonation the audit records the acting user and the real one" do
    admin = create(:user, company: @company)
    impersonated = UserSession.start!(user: @user, impersonator: admin)
    connector, = connector_with_operation

    approve(connector, user_session: impersonated)

    audit = Audit.where(action: "authoring.approved", auditable: connector).last
    assert_equal @user, audit.user
    assert_equal admin.id, audit.audited_changes["impersonator_id"]
    assert_includes audit.comment, admin.email
  end

  test "approving a module does not make its manifest editable afterwards" do
    block = propose(:module_definition, :proposed, :control_block, scope: @project)
    approve(block)

    assert_not block.reload.update(manifest: block.manifest.merge("label" => "Changed"))
  end
end

# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ApiConnectorReviewsTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    @connector = create(:api_connector, :bearer, :proposed, scope: @project, name: "billing", base_url: "https://api.example.com/v1")
    @operation = create(:api_operation, :proposed, api_connector: @connector, name: "create_invoice", http_method: "POST",
                                                   path: "/invoices", effect: "write")
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  def json = response.parsed_body

  def digest(record) = Authoring::Review.digest_for(record)

  def approve(connector: @connector, **params)
    enabled { post approve_company_project_api_connector_path(@project, connector), params: params, as: :json }
  end

  def reject(connector: @connector, **params)
    enabled { post reject_company_project_api_connector_path(@project, connector), params: params, as: :json }
  end

  test "review lists what the reviewer is asked to approve and which secret goes to which host" do
    block = create(:module_definition, :control_block, :proposed, scope: @project, namespace: "local", slug: "bill-it")
    block.update_columns(manifest: block.manifest.merge("executor" => "action", "uses" => { "transport" => "rest", "connection" => "billing", "operation" => "create_invoice" }))

    enabled { get review_company_project_api_connector_path(@project, @connector), as: :json }

    assert_response :success
    assert_equal "billing", json.dig("connector", "name")
    assert_equal digest(@connector), json.dig("connector", "reviewDigest")
    assert_equal [ "EXAMPLE_TOKEN → api.example.com" ], json["secretBindings"]
    assert_equal "api.example.com", json["host"]
    assert_equal [ [ @operation.id, digest(@operation) ] ], json["operations"].map { |op| [ op["id"], op["reviewDigest"] ] }
    assert_equal [ "local/bill-it@1" ], json["blocks"].pluck("key")
  end

  test "the review payload carries every column the digest covers, or names it as hidden on purpose" do
    hidden = { "ApiConnector" => %w[scope_type scope_id], "ApiOperation" => %w[api_connector_id] }
    enabled { get review_company_project_api_connector_path(@project, @connector), as: :json }

    { "ApiConnector" => json["connector"], "ApiOperation" => json["operations"].first }.each do |type, shown|
      Authoring::Review::CONTENT_COLUMNS.fetch(type).each do |column|
        assert shown.key?(column.camelize(:lower)) || hidden.fetch(type).include?(column),
               "#{type}##{column} is covered by the digest but neither shown to the reviewer nor listed as hidden on purpose"
      end
    end
  end

  test "review of another project's connector is a 404" do
    other = create(:api_connector, :proposed, scope: create(:project, company: @company, owner: @user))

    enabled { get review_company_project_api_connector_path(@project, other), as: :json }

    assert_response :not_found
  end

  test "approve without the digest the reviewer saw is refused and nothing is enabled" do
    approve

    assert_response :unprocessable_content
    assert_not @connector.reload.reviewed?
    assert_not @connector.enabled?
  end

  test "approve stamps the connector and the operations it was shown, and audits each" do
    approve(expected_digest: digest(@connector), operation_digests: { @operation.id.to_s => digest(@operation) })

    assert_response :success
    assert @connector.reload.reviewed?
    assert @connector.enabled?
    assert @operation.reload.reviewed?
    assert @operation.enabled?
    assert_equal @user.id, @connector.reviewed_by_id
    assert_equal 2, Audit.where(action: "authoring.approved").count
  end

  test "an operation added after the review was shown stays waiting" do
    later = create(:api_operation, :proposed, api_connector: @connector, name: "delete_invoice", http_method: "DELETE", path: "/x", effect: "irreversible")

    approve(expected_digest: digest(@connector), operation_digests: { @operation.id.to_s => digest(@operation) })

    assert_response :success
    assert_not later.reload.reviewed?
    assert_not later.enabled?
  end

  test "approve answers 409 when the connector changed after it was shown" do
    shown = digest(@connector)
    @connector.update!(base_url: "https://evil.example.net/v1")

    approve(expected_digest: shown)

    assert_response :conflict
    assert_not @connector.reload.reviewed?
  end

  test "approve answers 409 when an operation changed after it was shown" do
    shown = digest(@operation)
    @operation.update!(path: "/other")

    approve(expected_digest: digest(@connector), operation_digests: { @operation.id.to_s => shown })

    assert_response :conflict
    assert_not @connector.reload.reviewed?, "all or nothing"
    assert_not @operation.reload.reviewed?
  end

  test "an operation of another connector cannot ride along" do
    foreign = create(:api_operation, :proposed, api_connector: create(:api_connector, :proposed, scope: @project))

    approve(expected_digest: digest(@connector), operation_digests: { foreign.id.to_s => digest(foreign) })

    assert_response :not_found
    assert_not @connector.reload.reviewed?
    assert_not foreign.reload.reviewed?
  end

  test "approve is a 404 across projects" do
    other_project = create(:project, company: @company, owner: @user)
    other = create(:api_connector, :proposed, scope: other_project)

    approve(connector: other, expected_digest: digest(other))

    assert_response :not_found
    assert_not other.reload.reviewed?
  end

  test "approving a reviewed connector's waiting operation needs the connector digest and the operation digest" do
    reviewed = create(:api_connector, scope: @project, name: "reviewed-one")
    waiting = create(:api_operation, :proposed, api_connector: reviewed, name: "list_things")

    approve(connector: reviewed, expected_digest: digest(reviewed), operation_digests: { waiting.id.to_s => digest(waiting) })

    assert_response :success
    assert waiting.reload.reviewed?
  end

  test "approving operations of a reviewed connector is bound to the connector digest too" do
    reviewed = create(:api_connector, scope: @project, name: "reviewed-four")
    waiting = create(:api_operation, :proposed, api_connector: reviewed, name: "list_things")
    shown = digest(reviewed)
    reviewed.update!(base_url: "https://evil.example.net/v1")

    approve(connector: reviewed, expected_digest: shown, operation_digests: { waiting.id.to_s => digest(waiting) })

    assert_response :conflict
    assert_not waiting.reload.reviewed?
  end

  test "approving operations of a reviewed connector needs the connector digest" do
    reviewed = create(:api_connector, scope: @project, name: "reviewed-five")
    waiting = create(:api_operation, :proposed, api_connector: reviewed, name: "list_things")

    approve(connector: reviewed, operation_digests: { waiting.id.to_s => digest(waiting) })

    assert_response :unprocessable_content
    assert_not waiting.reload.reviewed?
  end

  test "approving something already reviewed is refused" do
    approve(expected_digest: digest(@connector))
    approve(expected_digest: digest(@connector.reload))

    assert_response :unprocessable_content
  end

  test "approve with nothing to approve is refused" do
    reviewed = create(:api_connector, scope: @project, name: "reviewed-two")

    approve(connector: reviewed)

    assert_response :unprocessable_content
  end

  test "an operation cannot be approved under an unreviewed connector" do
    approve(operation_digests: { @operation.id.to_s => digest(@operation) })

    assert_response :unprocessable_content
    assert_not @operation.reload.reviewed?
  end

  test "reject of a waiting connector rejects it and its waiting operations and keeps them off" do
    reject

    assert_response :success
    assert @connector.reload.rejected?
    assert @operation.reload.rejected?
    assert_not @connector.enabled?
    assert_equal 2, Audit.where(action: "authoring.rejected").count
    approve(expected_digest: digest(@connector))
    assert_response :not_found, "a rejected connector is archived, so it can't be approved afterwards"
  end

  test "reject of waiting operations on a reviewed connector" do
    reviewed = create(:api_connector, scope: @project, name: "reviewed-three")
    waiting = create(:api_operation, :proposed, api_connector: reviewed, name: "list_things")

    reject(connector: reviewed, operation_ids: [ waiting.id ])

    assert_response :success
    assert waiting.reload.rejected?
    assert_not reviewed.reload.rejected?
  end

  test "the feature flag gates the review endpoints" do
    post approve_company_project_api_connector_path(@project, @connector), params: { expected_digest: digest(@connector) }, as: :json

    assert_response :not_found
    assert_not @connector.reload.reviewed?
  end

  test "a request with only a bearer token is refused by authentication" do
    reset!

    with_feature(:workflow_action_steps, true) do
      post approve_company_project_api_connector_path(@project, @connector), params: { expected_digest: digest(@connector) },
                                                                              headers: { "Authorization" => "Bearer #{SecureRandom.hex(16)}" }, as: :json
    end

    assert_redirected_to login_path
    assert_not @connector.reload.reviewed?
  end
end

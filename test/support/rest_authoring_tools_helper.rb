# frozen_string_literal: true

# A project with the action-step flag on, its writer, and the Aixle Builder session that writer owns: what every tool of
# the agent door needs. `run_tool` calls a tool the way the Builder does (project pinned, session attached), and
# `run_personal` the way a personal MCP token does (no session).
module RestAuthoringToolsHelper
  SECRET_VALUE = "very-secret-value-0123456789"

  def build_authoring_world
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company)
    @project = create(:project, company: @company, owner: @user)
    enable_company_feature(:workflow_action_steps, @company)
    @builder = create(:terminal_session, :aixle_builder, user: @user, project: @project)
    @secret = create(:config_item, scope: @project, name: "BILLING_TOKEN", item_type: :secret, value: SECRET_VALUE)
    resolve_hosts_publicly!
  end

  def enable_company_feature(key, company)
    flag = FeatureFlag.find_or_create_by!(key: key.to_s)
    flag.overrides.find_or_initialize_by(company: company).update!(enabled: true, reason: "test")
    Current.feature_snapshot = nil
  end

  def run_tool(klass, params, project: @project, session: @builder, user: @user)
    klass.new(params: { "project_id" => project.id }.merge(params.deep_stringify_keys), user: user, pinned_project: project, session: session).execute
  end

  def run_personal(klass, params, user: @user)
    klass.new(params: params.deep_stringify_keys, user: user).execute
  end

  def payload(result) = JSON.parse(result[:stdout])

  def assert_ok(result)
    assert_equal 0, result[:exit_code], result[:stderr].presence || result[:stdout]
    payload(result)
  end

  def assert_refused(result, pattern = nil)
    assert_equal 1, result[:exit_code], result[:stdout]
    assert_match(pattern, result[:stderr]) if pattern
    result[:stderr]
  end

  def operation_spec(name = "list_invoices", **overrides)
    { name: name, method: "GET", path: "/invoices", effect: "read", summary: "List invoices",
      input_schema: { "type" => "object", "properties" => { "query" => { "type" => "object", "properties" => { "limit" => { "type" => "integer" } } } } } }.merge(overrides)
  end

  def connector_params(**overrides)
    { name: "billing", base_url: "https://api.example.com/v1", auth_type: "bearer",
      auth_config: { config_item_name: "BILLING_TOKEN" }, description: "Invoices", operations: [ operation_spec ] }.merge(overrides)
  end

  # What a person does in the review drawer: approve the records, bound to the content they were shown.
  def approve_as_person!(*records, user: @user, project: @project)
    Authoring::Review.approve!(records, user_session: UserSession.start!(user: user), project: project,
                                        expected_digests: records.to_h { |record| [ record, Authoring::Review.digest_for(record) ] })
  end

  def propose_connector!(**overrides)
    body = assert_ok(run_tool(PersonalTools::ProposeRestConnector, connector_params(**overrides)))
    ApiConnector.find(body["connector"]["id"])
  end

  def assert_no_secret(*results)
    results.each do |result|
      assert_not_includes result.to_json, SECRET_VALUE, "a tool result carried a secret value"
    end
  end
end

ActiveSupport::TestCase.include(RestAuthoringToolsHelper)

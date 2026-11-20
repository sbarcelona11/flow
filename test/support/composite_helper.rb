# frozen_string_literal: true

# A project whose workflow reads, summarises, asks for approval and sends, for the composite block tests.
module CompositeHelper
  def build_composite_project
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    enable_company_feature(:workflow_action_steps, @company)
    enable_company_feature(:automations_canvas, @company)
    @connector = create(:api_connector, scope: @project, name: "billing")
    @operation = create(:api_operation, api_connector: @connector, name: "get_invoice")
    @workflow = create(:workflow, scope: @project, name: "Invoices")
  end

  def enable_company_feature(key, company)
    flag = FeatureFlag.find_or_create_by!(key: key.to_s)
    flag.overrides.find_or_initialize_by(company: company).update!(enabled: true, reason: "test")
    Current.feature_snapshot = nil
  end

  def rest_config(effect, **extra)
    { "target" => "rest_operation", "api_operation_id" => @operation.id, "effect" => effect }.merge(extra)
  end

  # fetch -> summarise -> approve -> send, saved.
  def build_pipeline
    @fetch = create(:step, workflow: @workflow, name: "Fetch invoice", position: 1, kind: "action",
                           kind_config: rest_config("read", "output_name" => "invoice.json", "arguments" => { "id" => "42" }))
    @summarise = create(:step, workflow: @workflow, name: "Summarise", position: 2, depends_on_step_ids: [ @fetch.id ],
                               instructions: "Summarise {{output:#{@fetch.id}:invoice.json}}",
                               output_asset_specs: [ { "name" => "summary.md" } ], budget_cents: 40)
    @approve = create(:step, workflow: @workflow, name: "Approve", position: 3, kind: "approval", depends_on_step_ids: [ @summarise.id ])
    @send = create(:step, workflow: @workflow, name: "Send invoice", position: 4, kind: "action", depends_on_step_ids: [ @approve.id ],
                          kind_config: rest_config("send", "output_name" => "sent.json",
                                                           "arguments" => { "body" => "{{output:#{@summarise.id}:summary.md}}" }))
  end

  def stamp_composite(manifest, project: @project, enabled: true)
    create(:module_definition, scope: project, kind: "block", namespace: manifest["namespace"], slug: manifest["slug"],
                               version: manifest["version"], manifest: manifest, enabled: enabled)
  end
end

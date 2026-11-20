# frozen_string_literal: true

require "test_helper"

class Web::Company::Projects::ModuleDefinitionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @company = create(:company)
    @user = create(:user, :admin, :onboarding_completed, company: @company, password: AuthHelper::TEST_PASSWORD)
    @project = create(:project, company: @company, owner: @user)
    @connector = create(:api_connector, scope: @project, name: "billing")
    @operation = create(:api_operation, api_connector: @connector, name: "create_invoice", http_method: "POST", effect: "write",
                                        input_schema: { "type" => "object",
                                                        "properties" => { "body" => { "type" => "object",
                                                                                      "properties" => { "amount" => { "type" => "integer" } } } } })
    sign_in_as(@user)
  end

  def enabled(&block) = with_feature(:workflow_action_steps, true, company: @company, &block)

  def json = response.parsed_body

  def manifest_for(slug, **fields)
    { "kind" => "block", "namespace" => "local", "slug" => slug, "version" => 1, "label" => slug.titleize, "executor" => "control",
      "control" => "approval", "ports" => { "in" => { "subject" => "aixle/string@1" }, "out" => { "decision" => "aixle/string@1" } } }.merge(fields)
  end

  def from_operation(**overrides)
    { from_operation: { api_operation_id: @operation.id, label: "Create invoice" }.merge(overrides) }
  end

  def proposal(slug = "proposed-block")
    create(:module_definition, :control_block, :proposed, scope: @project, namespace: "local", slug: slug)
  end

  def approve(definition, digest: Authoring::Review.digest_for(definition))
    enabled { post approve_company_project_module_definition_path(@project, definition), params: { expected_digest: digest }, as: :json }
  end

  test "index lists every definition with archived ones flagged, plus review state, origin, status and reason" do
    live = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "live")
    gone = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "gone")
    gone.archive!
    waiting = proposal
    create(:module_definition, :control_block, scope: create(:project, company: @company, owner: @user), namespace: "local", slug: "other")

    enabled { get company_project_module_definitions_path(@project), as: :json }

    assert_response :success
    assert_equal false, json["truncated"] # rubocop:disable Minitest/RefuteFalse
    rows = json["definitions"].index_by { |row| row["slug"] }
    assert_equal %w[gone live proposed-block], rows.keys.sort
    assert_equal [ "reviewed", "web", true, nil ], rows["live"].values_at("reviewState", "origin", "enabled", "archivedAt")
    assert_equal "valid", rows["live"]["status"]
    assert_not_nil rows["gone"]["archivedAt"]
    assert_equal [ "waiting", "builder", false ], rows["proposed-block"].values_at("reviewState", "origin", "enabled")
    assert_equal "local/proposed-block@1", rows["proposed-block"]["key"]
    assert_equal Authoring::Review.digest_for(waiting), rows["proposed-block"]["reviewDigest"]
    assert_nil rows["live"]["manifest"]
    assert_not_nil live
  end

  test "show includes the manifest" do
    definition = proposal

    enabled { get company_project_module_definition_path(@project, definition), as: :json }

    assert_response :success
    assert_equal definition.manifest, json["manifest"]
    assert_equal "control", json["manifest"]["executor"]
  end

  test "create from an operation stamps the web user, uses the local namespace and returns a valid block" do
    assert_difference -> { ModuleDefinition.count }, 1 do
      enabled { post company_project_module_definitions_path(@project), params: from_operation(settings: %w[amount]), as: :json }
    end

    assert_response :created
    definition = ModuleDefinition.last
    assert_equal [ "local", "create-invoice", 1, "block" ], definition.values_at(:namespace, :slug, :version, :kind)
    assert_equal [ "web", @user.id, @user.id, true ], [ definition.origin, definition.created_by_id, definition.reviewed_by_id, definition.enabled ]
    assert_equal "write", definition.manifest["effect"]
    assert_equal [ "valid", "reviewed" ], json.values_at("status", "reviewState")
    assert_kind_of Array, json["warnings"]
  end

  test "create from an operation never lowers the effect" do
    enabled { post company_project_module_definitions_path(@project), params: from_operation(effect: "read"), as: :json }

    assert_equal "write", ModuleDefinition.last.manifest["effect"]
  end

  test "create from an operation refuses an unknown setting and a blank label" do
    enabled { post company_project_module_definitions_path(@project), params: from_operation(settings: %w[nope]), as: :json }
    assert_response :unprocessable_content
    assert_match(/nope/, json["error"])

    enabled { post company_project_module_definitions_path(@project), params: from_operation(label: ""), as: :json }
    assert_response :unprocessable_content
    assert_equal 0, ModuleDefinition.count
  end

  test "an operation id from another project is a 404 and creates nothing" do
    foreign = create(:api_operation)

    enabled { post company_project_module_definitions_path(@project), params: { from_operation: { api_operation_id: foreign.id, label: "x" } }, as: :json }

    assert_response :not_found
    assert_equal 0, ModuleDefinition.count
  end

  test "create from a pasted manifest" do
    enabled { post company_project_module_definitions_path(@project), params: { manifest: manifest_for("ask-first").to_yaml }, as: :json }

    assert_response :created
    definition = ModuleDefinition.find_by!(slug: "ask-first")
    assert_equal [ "web", @user.id, true ], [ definition.origin, definition.reviewed_by_id, definition.enabled ]
  end

  test "a pasted manifest with aliases, a reference or an oversize body is refused with the manifest's message" do
    aliased = "kind: type\nnamespace: local\nslug: a\nversion: 1\nlabel: &l A\nschema: {type: string}\ndescription: *l\n"
    with_ref = manifest_for("ref", "executor" => "action", "uses" => { "transport" => "rest", "connection" => "billing", "operation" => "x" },
                                   "ports" => { "in" => {}, "out" => {} }, "config" => { "type" => "object", "properties" => { "a" => { "$ref" => "#/x" } } })
    with_ref.delete("control")

    [ [ aliased, /aliases/ ], [ with_ref.to_json, /\$ref/ ], [ "x" * (Modules::Manifest::MAX_BYTES + 1), /256 KB/ ] ].each do |body, message|
      enabled { post company_project_module_definitions_path(@project), params: { manifest: body }, as: :json }
      assert_response :unprocessable_content
      assert_match message, json["error"]
    end
    assert_equal 0, ModuleDefinition.count
  end

  test "a pasted manifest naming another project's connector is stored but resolves as invalid" do
    other = create(:project, company: @company, owner: @user)
    create(:api_connector, scope: other, name: "elsewhere")
    manifest = manifest_for("leaky", "executor" => "action", "uses" => { "transport" => "rest", "connection" => "elsewhere", "operation" => "x" },
                                     "ports" => { "in" => {}, "out" => {} })
    manifest.delete("control")

    enabled { post company_project_module_definitions_path(@project), params: { manifest: manifest.to_json }, as: :json }

    assert_response :created
    assert_equal "invalid", json["status"]
    assert_match(/elsewhere/, json["reason"])
  end

  test "create needs exactly one of from_operation and manifest" do
    enabled { post company_project_module_definitions_path(@project), params: {}, as: :json }
    assert_response :unprocessable_content

    enabled { post company_project_module_definitions_path(@project), params: from_operation.merge(manifest: "x"), as: :json }
    assert_response :unprocessable_content
  end

  test "approve stamps the signed-in user, enables the module and audits it" do
    definition = proposal

    approve(definition)

    assert_response :success
    definition.reload
    assert_equal [ true, @user.id ], [ definition.enabled, definition.reviewed_by_id ]
    assert_equal [ "reviewed", true ], [ json["reviewState"], json["enabled"] ]
    assert Audit.exists?(auditable: definition, action: "authoring.approved", user_id: @user.id)
  end

  test "approve needs the digest of what the reviewer saw" do
    definition = proposal

    approve(definition, digest: nil)

    assert_response :unprocessable_content
    assert_not definition.reload.reviewed?
  end

  test "approve refuses a module that changed after it was shown (409 with a clear message)" do
    definition = proposal
    seen = Authoring::Review.digest_for(definition)
    definition.update!(manifest: definition.manifest.merge("label" => "Changed behind your back"))

    approve(definition, digest: seen)

    assert_response :conflict
    assert_match(/changed after it was shown for review/, json["error"])
    assert_not definition.reload.reviewed?
  end

  test "approve refuses an already reviewed or rejected module" do
    reviewed = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "done")
    approve(reviewed)
    assert_response :unprocessable_content

    rejected = proposal("nope")
    rejected.update!(rejected_at: Time.current, rejected_by: @user)
    approve(rejected)
    assert_response :unprocessable_content
    assert_not rejected.reload.enabled?

    gone = proposal("gone")
    enabled { post reject_company_project_module_definition_path(@project, gone), as: :json }
    approve(gone)
    assert_response :not_found
  end

  test "reject archives and marks the proposal rejected" do
    definition = proposal

    enabled { post reject_company_project_module_definition_path(@project, definition), as: :json }

    assert_response :success
    definition.reload
    assert_equal [ "rejected", true, false ], [ definition.review_state, definition.archived?, definition.enabled ]
    assert Audit.exists?(auditable: definition, action: "authoring.rejected")
  end

  test "enable, disable and archive work on a reviewed module, and enable refuses an unreviewed one" do
    definition = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "toggle")

    enabled { post disable_company_project_module_definition_path(@project, definition), as: :json }
    assert_response :success
    assert_not definition.reload.enabled?

    enabled { post enable_company_project_module_definition_path(@project, definition), as: :json }
    assert definition.reload.enabled?

    enabled { post archive_company_project_module_definition_path(@project, definition), as: :json }
    assert_response :success
    assert definition.reload.archived?

    waiting = proposal
    enabled { post enable_company_project_module_definition_path(@project, waiting), as: :json }
    assert_response :unprocessable_content
    assert_not waiting.reload.enabled?
  end

  test "new_version of a reviewed v1 creates v2 and leaves v1 untouched" do
    v1 = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "ask-first")
    before = v1.attributes.slice("manifest", "reviewed_at", "enabled", "digest")
    changed = manifest_for("ask-first", "label" => "Ask first, v2", "version" => 7)

    assert_difference -> { ModuleDefinition.count }, 1 do
      enabled { post new_version_company_project_module_definition_path(@project, v1), params: { manifest: changed.to_json }, as: :json }
    end

    assert_response :created
    v2 = ModuleDefinition.find_by!(slug: "ask-first", version: 2)
    assert_equal "Ask first, v2", v2.manifest["label"]
    assert_equal [ "web", @user.id ], [ v2.origin, v2.reviewed_by_id ]
    assert_equal before, v1.reload.attributes.slice("manifest", "reviewed_at", "enabled", "digest")
  end

  test "new_version from an operation keeps the slug and takes the next version" do
    enabled { post company_project_module_definitions_path(@project), params: from_operation, as: :json }
    v1 = ModuleDefinition.last

    enabled { post new_version_company_project_module_definition_path(@project, v1), params: from_operation(label: "Create invoice v2"), as: :json }

    assert_response :created
    assert_equal [ "create-invoice", 2 ], ModuleDefinition.order(:id).last.values_at(:slug, :version)
  end

  test "new_version refuses a different namespace, slug or kind" do
    v1 = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "ask-first")

    [ manifest_for("other-slug"), manifest_for("ask-first", "namespace" => "acme"), manifest_for("ask-first", "kind" => "type") ].each do |manifest|
      enabled { post new_version_company_project_module_definition_path(@project, v1), params: { manifest: manifest.to_json }, as: :json }
      assert_response :unprocessable_content
    end
    assert_equal 1, ModuleDefinition.count
  end

  test "definitions of another project are a 404 for every member action" do
    foreign = create(:module_definition, :control_block, :proposed, scope: create(:project, company: @company, owner: @user), namespace: "local", slug: "x")

    enabled do
      get company_project_module_definition_path(@project, foreign), as: :json
      assert_response :not_found
      %i[approve reject enable disable archive new_version].each do |action|
        post public_send(:"#{action}_company_project_module_definition_path", @project, foreign), params: { expected_digest: "x", manifest: "{}" }, as: :json
        assert_response :not_found, action.to_s
      end
    end
    assert_not foreign.reload.reviewed?
  end

  test "a request without the flag is a 404" do
    get company_project_module_definitions_path(@project), as: :json

    assert_response :not_found
  end

  test "an archived definition is not found for member actions" do
    definition = proposal
    definition.archive!

    approve(definition)

    assert_response :not_found
  end

  test "a request with only a bearer token is refused by authentication, not by the feature gate" do
    definition = proposal
    reset!

    with_feature(:workflow_action_steps, true) do
      post approve_company_project_module_definition_path(@project, definition),
           params: { expected_digest: Authoring::Review.digest_for(definition) },
           headers: { "Authorization" => "Bearer #{SecureRandom.hex(16)}" }, as: :json
    end

    assert_redirected_to login_path
    assert_not definition.reload.reviewed?
    assert_not definition.enabled?
  end

  test "no token-authenticated API route reaches the module definition actions" do
    routes = Rails.application.routes.routes.select { |route| route.defaults[:controller].to_s.end_with?("module_definitions") }

    assert routes.any?
    assert(routes.all? { |route| route.defaults[:controller] == "web/company/projects/module_definitions" })
  end

  test "new_version of a waiting tool proposal creates a waiting v2, never a reviewed one" do
    waiting = proposal("agent-made")

    assert_difference -> { Audit.where(action: "authoring.proposed").count }, 1 do
      enabled { post new_version_company_project_module_definition_path(@project, waiting), params: { manifest: manifest_for("agent-made").to_json }, as: :json }
    end

    assert_response :created
    v2 = ModuleDefinition.find_by!(slug: "agent-made", version: 2)
    assert_equal [ "waiting", false, "builder" ], [ v2.review_state, v2.enabled, v2.origin ]
    assert_equal [ "waiting", "waiting" ], [ json["reviewState"], waiting.reload.review_state ]
  end

  test "new_version of an approved tool-made module is also waiting" do
    reviewed = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "agent-ok", origin: "builder")

    enabled { post new_version_company_project_module_definition_path(@project, reviewed), params: { manifest: manifest_for("agent-ok").to_json }, as: :json }

    assert_response :created
    assert_equal "waiting", ModuleDefinition.find_by!(slug: "agent-ok", version: 2).review_state
  end

  test "archiving a waiting proposal is an audited rejection" do
    waiting = proposal

    enabled { post archive_company_project_module_definition_path(@project, waiting), as: :json }

    assert_response :success
    assert_equal [ "rejected", true ], [ waiting.reload.review_state, waiting.archived? ]
    assert Audit.exists?(auditable: waiting, action: "authoring.rejected", user_id: @user.id)
  end

  test "archiving a reviewed definition is audited" do
    reviewed = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "retire")

    enabled { post archive_company_project_module_definition_path(@project, reviewed), as: :json }

    assert_response :success
    assert reviewed.reload.archived?
    assert_not reviewed.enabled?
    assert Audit.exists?(auditable: reviewed, action: "authoring.archived", user_id: @user.id)
  end

  test "show opens an archived definition the index lists" do
    gone = create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "gone")
    gone.archive!

    enabled { get company_project_module_definition_path(@project, gone), as: :json }

    assert_response :success
    assert_equal gone.manifest, json["manifest"]
    assert_not_nil json["archivedAt"]
  end

  test "index discloses when it stops at the listing limit" do
    3.times { |i| create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "row-#{i}") }
    original = Web::Company::Projects::ModuleDefinitionsController.listing_limit
    Web::Company::Projects::ModuleDefinitionsController.listing_limit = 2

    enabled { get company_project_module_definitions_path(@project), as: :json }

    assert_equal [ 2, true ], [ json["definitions"].size, json["truncated"] ]
  ensure
    Web::Company::Projects::ModuleDefinitionsController.listing_limit = original
  end

  test "index validates the project's enabled manifests once, however many rows are not enabled" do
    20.times { |i| create(:module_definition, :control_block, scope: @project, namespace: "local", slug: "on-#{i}") }
    20.times { |i| create(:module_definition, :control_block, :proposed, scope: @project, namespace: "local", slug: "off-#{i}") }
    validations = 0
    original = Modules::Manifest.method(:from_hash)
    counting = lambda do |data|
      validations += 1
      original.call(data)
    end
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }

    Modules::Manifest.stub(:from_hash, counting) do
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        enabled { get company_project_module_definitions_path(@project), as: :json }
      end
    end

    assert_equal 40, json["definitions"].size
    assert_equal [ "valid" ], json["definitions"].map { |row| row["status"] }.uniq
    assert_operator validations, :<=, 100, "validations must grow with rows, not rows squared"
    assert_operator queries, :<=, 40, "queries must not grow per row"
  end

  test "index is limited to 60 a minute per user" do
    limits = ActiveSupport::Cache::MemoryStore.new
    store = Web::Company::Projects::ModuleDefinitionsController.cache_store

    store.stub(:increment, ->(*args, **options) { limits.increment(*args, **options) }) do
      enabled do
        60.times do
          get company_project_module_definitions_path(@project), as: :json
          assert_response :success
        end
        get company_project_module_definitions_path(@project), as: :json
      end
    end

    assert_response :too_many_requests
  end

  test "an unexpected ArgumentError is not turned into a 422 carrying its message" do
    Modules::BlockBuilder.stub(:from_operation, ->(**) { raise ArgumentError, "internal detail" }) do
      assert_raises(ArgumentError) do
        enabled { post company_project_module_definitions_path(@project), params: from_operation, as: :json }
      end
    end
  end

  test "creating is limited to 20 a minute per user" do
    limits = ActiveSupport::Cache::MemoryStore.new
    store = Web::Company::Projects::ModuleDefinitionsController.cache_store
    create_one = ->(index) { post company_project_module_definitions_path(@project), params: { manifest: manifest_for("m-#{index}").to_json }, as: :json }

    store.stub(:increment, ->(*args, **options) { limits.increment(*args, **options) }) do
      enabled do
        20.times do |index|
          create_one.call(index)
          assert_response :created
        end
        create_one.call(21)
      end
    end

    assert_response :too_many_requests
    assert_match(/Too many/, json["error"])
  end
end

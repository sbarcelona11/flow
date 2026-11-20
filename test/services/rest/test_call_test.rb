# frozen_string_literal: true

require "test_helper"

module Rest
  class TestCallTest < ActiveSupport::TestCase
    BASE = "https://api.example.com/v1"

    setup do
      resolve_hosts_publicly!
      @company = create(:company)
      @user = create(:user, company: @company)
      @project = create(:project, company: @company, owner: @user)
      @connector = create(:api_connector, scope: @project, base_url: BASE)
      @operation = create(:api_operation, :with_path_param, api_connector: @connector, name: "get_thing")
    end

    def run_call(operation = @operation, arguments: { "path" => { "id" => "7" } })
      TestCall.run(operation: operation, arguments: arguments, user: @user, project: @project)
    end

    def stub_thing = stub_request(:get, "#{BASE}/things/7")

    def audit = Audit.where(action: "rest.test_call").order(:id).last

    test "returns a pretty preview of a JSON answer" do
      stub_thing.to_return(status: 200, body: { "id" => 7 }.to_json, headers: { "Content-Type" => "application/json" })

      result = run_call

      assert_equal [ true, 200, false, nil ], result.values_at(:ok, :status, :truncated, :error)
      assert_equal({ "id" => 7 }, JSON.parse(result[:preview]))
    end

    test "returns a text answer as it is" do
      stub_thing.to_return(status: 200, body: "plain", headers: { "Content-Type" => "text/plain" })

      assert_equal "plain", run_call[:preview]
    end

    test "a secret the API echoes is absent from the preview and the error" do
      create(:config_item, scope: @project, name: "THING_TOKEN", item_type: :secret, value: "tok-very-secret-1")
      @connector.update!(auth_type: "bearer", auth_config: { "config_item_name" => "THING_TOKEN" })
      stub_thing.to_return(status: 200, body: { "echo" => "Bearer tok-very-secret-1", "raw" => "tok-very-secret-1" }.to_json,
                           headers: { "Content-Type" => "application/json" })

      result = run_call
      assert result[:ok]
      assert_not_includes result[:preview], "tok-very-secret-1"
      assert_includes result[:preview], "[redacted]"

      stub_thing.to_return(status: 401, body: "bad token tok-very-secret-1")
      failed = run_call
      assert_not failed[:ok]
      assert_equal 401, failed[:status]
      assert_not_includes failed[:error], "tok-very-secret-1"
      assert_nil failed[:preview]
    end

    test "truncates the preview at 64 KB and says so" do
      stub_thing.to_return(status: 200, body: "é" * 100_000, headers: { "Content-Type" => "text/plain" })

      result = run_call

      assert result[:truncated]
      assert_operator result[:preview].bytesize, :<=, TestCall::PREVIEW_BYTES
      assert result[:preview].valid_encoding?
    end

    test "a secret cannot survive by being cut in half at the limit" do
      create(:config_item, scope: @project, name: "THING_TOKEN", item_type: :secret, value: "tok-boundary-secret")
      @connector.update!(auth_type: "bearer", auth_config: { "config_item_name" => "THING_TOKEN" })
      body = ("a" * (TestCall::PREVIEW_BYTES - 5)) + "tok-boundary-secret"
      stub_thing.to_return(status: 200, body: body, headers: { "Content-Type" => "text/plain" })

      result = run_call

      assert_not_includes result[:preview], "tok-b"
    end

    test "a write operation is refused and no request is made" do
      write = create(:api_operation, api_connector: @connector, name: "make_thing", http_method: "POST", effect: "write", path: "/things")

      result = run_call(write, arguments: {})

      assert_not result[:ok]
      assert_match(/Only read operations/, result[:error])
      assert_not_requested :any, /api\.example\.com/
      assert_equal "refused", audit.audited_changes["outcome"]
    end

    test "each refusal names its own reason and makes no request" do
      refusals = {
        /switched off/ => -> { @connector.update!(enabled: false) },
        /waiting for review. Approve it/ => -> { @connector.update_columns(reviewed_at: nil, enabled: false) },
        /is archived/ => -> { @connector.archive! },
        /get_thing is switched off/ => -> { @operation.update!(enabled: false) },
        /get_thing is waiting for review/ => -> { @operation.update_columns(reviewed_at: nil, enabled: false) }
      }

      refusals.each do |reason, change|
        change.call
        result = run_call
        assert_not result[:ok], reason.inspect
        assert_nil result[:status], reason.inspect
        assert_match reason, result[:error]
        @connector.reload.update_columns(enabled: true, reviewed_at: Time.current, archived_at: nil)
        @operation.reload.update_columns(enabled: true, reviewed_at: Time.current)
      end
      assert_not_requested :any, /api\.example\.com/
    end

    test "a GET operation whose effect is above read is refused, and so is a read effect on another verb" do
      %w[write send].each do |effect|
        operation = create(:api_operation, api_connector: @connector, name: "get_#{effect}", http_method: "GET", effect: effect, path: "/things")
        assert_match(/Only read operations/, run_call(operation, arguments: {})[:error], effect)
      end
      post = create(:api_operation, api_connector: @connector, name: "post_op", http_method: "POST", effect: "write", path: "/things")
      post.update_columns(effect: "read")
      assert_match(/Only read operations/, run_call(post, arguments: {})[:error])
      assert_not_requested :any, /api\.example\.com/
    end

    test "an operation outside the given project is refused before anything is read" do
      other = create(:project, company: @company, owner: @user)

      assert_raises(Authoring::Review::WrongProject) { TestCall.run(operation: @operation, arguments: { "path" => { "id" => "7" } }, user: @user, project: other) }
      assert_not_requested :any, /api\.example\.com/
      assert_equal 0, Audit.where(action: "rest.test_call").count
    end

    test "a URL-encoded echo of a secret is redacted" do
      create(:config_item, scope: @project, name: "THING_TOKEN", item_type: :secret, value: "tok+very/secret=1")
      @connector.update!(auth_type: "bearer", auth_config: { "config_item_name" => "THING_TOKEN" })
      stub_thing.to_return(status: 200, body: "seen tok%2Bvery%2Fsecret%3D1 and tok+very/secret=1", headers: { "Content-Type" => "text/plain" })

      preview = run_call[:preview]

      assert_not_includes preview, "tok%2B"
      assert_not_includes preview, "tok+very"
    end

    test "a redirect is not followed and its Location is not echoed" do
      stub_thing.to_return(status: 302, headers: { "Location" => "https://evil.example/steal" })

      result = run_call

      assert_not result[:ok]
      assert_not_includes result[:error], "evil.example"
      assert_not_requested :any, /evil\.example/
    end

    test "arguments are checked against the input schema before any request" do
      assert_not run_call(arguments: { "path" => {} })[:ok]
      assert_not run_call(arguments: { "path" => { "id" => 7 } })[:ok]
      assert_match(/not one of the arguments/, run_call(arguments: { "path" => { "id" => "7" }, "extra" => 1 })[:error])
      assert_match(/must be an object/, run_call(arguments: "x")[:error])
      assert_not_requested :any, /api\.example\.com/
    end

    test "a type error does not echo the value that was typed" do
      message = run_call(arguments: { "path" => { "id" => { "typed" => "SECRETVALUE" } } })[:error]

      assert_not_includes message, "SECRETVALUE"
    end

    test "the audit row holds the digest of the arguments, never the values" do
      stub_thing.to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      arguments = { "path" => { "id" => "7" } }

      run_call(arguments: arguments)

      row = audit
      assert_equal [ @operation, @user, @project ], [ row.auditable, row.user, row.associated ]
      assert_equal({ "type" => "ApiOperation", "arguments_digest" => Authoring::Review.arguments_digest(arguments), "status" => 200,
                     "outcome" => "ok", "host" => "api.example.com", "config_item_names" => [] }, row.audited_changes)
      assert_not_equal Digest::SHA256.hexdigest(arguments.to_json), row.audited_changes["arguments_digest"]
      assert_not_includes row.audited_changes.to_json, "\"7\""
      assert_not_includes row.comment, "7\""
    end

    test "the audit row names the host and the Config Item names the secret went with, never their values" do
      create(:config_item, scope: @project, name: "THING_TOKEN", item_type: :secret, value: "tok-audit-secret")
      @connector.update!(auth_type: "bearer", auth_config: { "config_item_name" => "THING_TOKEN" })
      stub_thing.to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      run_call

      assert_equal [ "api.example.com", [ "THING_TOKEN" ] ], audit.audited_changes.values_at("host", "config_item_names")
      assert_not_includes audit.audited_changes.to_json, "tok-audit-secret"
    end

    test "a failed call is audited too, and nothing is retried" do
      stub = stub_thing.to_return(status: 503, body: "down")

      result = run_call

      assert_not result[:ok]
      assert_equal "failed", audit.audited_changes["outcome"]
      assert_requested stub, times: 1
    end

    test "a connector pointing at a private address is refused by the SSRF check and no request is made" do
      @connector.update_columns(base_url: "https://10.0.0.5/v1")
      UrlSafetyValidator.unstub(:resolved_addresses)

      result = run_call

      assert_not result[:ok]
      assert_not_requested :any, /10\.0\.0\.5/
    end
  end
end

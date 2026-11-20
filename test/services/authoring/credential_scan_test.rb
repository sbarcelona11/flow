# frozen_string_literal: true

require "test_helper"

module Authoring
  class CredentialScanTest < ActiveSupport::TestCase
    # Built at run time so no secret scanner trips on this file.
    A = "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6q7R8"
    PROVIDER_SECRETS = {
      "stripe live" => "sk_live_#{A[0, 24]}", "stripe restricted" => "rk_live_#{A[0, 24]}", "stripe webhook" => "whsec_#{A[0, 32]}",
      "anthropic" => "sk-ant-api03-#{A}", "openai project" => "sk-proj-#{A}", "openai legacy" => "sk-#{A[0, 40]}",
      "github pat" => "ghp_#{A}", "github fine grained" => "github_pat_11#{A}#{A}", "gitlab" => "glpat-#{A[0, 24]}",
      "slack bot" => "xoxb-123456789012-#{A[0, 24]}", "aws access key" => "AKIAABCD1234EFGH5678", "google api key" => "AIza#{A[0, 35]}",
      "sendgrid" => "SG.#{A[0, 22]}.#{A[0, 22]}", "npm" => "npm_#{A}",
      "jwt" => "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1rwW1gFWFOEjXk",
      "pem private" => "-----BEGIN RSA PRIVATE KEY-----\nMIIE", "key in a sentence" => "call it with token=ghp_#{A} please"
    }.freeze
    AGENT_ONLY_SECRETS = {
      "bearer token" => "Authorization: Bearer abcdef1234567890abcdef", "basic credentials" => "Basic dXNlcjpwYXNzd29yZDEyMzQ1Ng==",
      "url with password" => "https://admin:hunter2pass@db.example.com/app"
    }.freeze
    LEGITIMATE = [
      "Basic authentication", "Bearer authentication", "Please enable Basic authentication on the staging server", "The API uses Bearer authentication",
      "See npm-package-installation-guide", "hf_internal_model_repository", "sk_customer_attribute_v2", "pk_user_profile_settings",
      "rk_regional_kitchen_list", "sk-learn-cross-validation-guide", "-----BEGIN PUBLIC KEY-----\nMFkw", "-----BEGIN CERTIFICATE-----\nMIID",
      "pk_test_#{A[0, 24]}", "https://api.example.com/v1/invoices?page=3", "0b6f5a52-3c1e-4c5e-9d3b-6f1c2a7e8d90",
      "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms",
      "dGhpcyBpcyBhIGZpbGUgaWQgZm9yIGEgdGVzdA==", "CAESBkFhYmJjYxABGAEiAA", "cus_NffrFeUfNV2Hib", "in_1MtHbELkdIwHu7ixYsmpA5Iu",
      "price_1MtHbELkdIwHu7ixraBm864M", "C024BE91L", "1503435956.000247", "ada@example.com", "recABC123xyz456", "Authorization is handled upstream",
      "tokens_used", "{{context:token}}", "Bearer {{context:token}}", "{{output:12:invoice.json}}", "Ada Lovelace",
      "https://bucket.s3.amazonaws.com/f?X-Amz-Signature=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      "q7Zk3VbN9xLw2RtY8mCd4HgF6sJp1AeU5oXi"
    ].freeze

    test "the agent-door scan refuses every secret form and none of the legitimate values" do
      PROVIDER_SECRETS.merge(AGENT_ONLY_SECRETS).each { |name, value| assert CredentialScan.credential?(value), name }
      LEGITIMATE.each { |value| assert_not CredentialScan.credential?(value), value }
    end

    test "the web warning covers whole provider keys, JWTs and private keys, and nothing legitimate" do
      PROVIDER_SECRETS.each { |name, value| assert CredentialScan.provider_key?(value), name }
      AGENT_ONLY_SECRETS.each { |name, value| assert_not CredentialScan.provider_key?(value), name }
      LEGITIMATE.each { |value| assert_not CredentialScan.provider_key?(value), value }
    end

    test "a key split by an invisible character is still found, and a placeholder around it is not a key" do
      assert CredentialScan.provider_key?("sk_live_​#{A[0, 24]}")
      assert_not CredentialScan.provider_key?("{{config_item:sk_live_#{A[0, 24]}}}")
    end

    test "the web warning is a warning in the issue channel, field = the argument, and never carries the value" do
      key = "sk_live_#{A[0, 24]}"
      node = DataFlow::Check::Node.new(key: "1", name: "Call", instructions: "", depends_on: [], asset_ids: [], attached: {}, inputs: [], outputs: [],
                                       arguments: { "query" => { "q" => key, "page_token" => "CAESBkFhYmJjYxABGAEiAA", "n" => "Basic authentication" } })
      company = create(:company)
      project = create(:project, company: company, owner: create(:user, company: company))
      check = DataFlow::Check.new(project: project, nodes: [ node ], config: {})

      warning = check.issues.find { |issue| issue.code == "credential_in_argument" }

      assert_equal [ "warning", "arguments.query.q" ], [ warning.severity, warning.field ]
      assert_not_includes warning.as_json.to_json, key
      assert_empty check.errors.select { |issue| issue.code == "credential_in_argument" }
      assert_equal 1, check.issues.count { |issue| issue.code == "credential_in_argument" }
    end
  end
end

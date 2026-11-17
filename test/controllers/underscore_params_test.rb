# frozen_string_literal: true

require "test_helper"

class UnderscoreParamsTest < ActionController::TestCase
  class EchoController < ApplicationController
    skip_before_action :require_login, raise: false

    def create
      render json: params.to_unsafe_h.except(:controller, :action, :format)
    end
  end

  tests EchoController

  setup do
    Rails.application.routes.draw { post "echo" => "underscore_params_test/echo#create" }
  end

  teardown { Rails.application.reload_routes! }

  test "keeps the tool arguments of a step's kind config verbatim and underscores everything else" do
    steps = [ { stepName: "a", kindConfig: { outputName: "r.json", arguments: { pageSize: 1, filter: { teamId: "x" } } } } ]

    post :create, params: { aggregate: { baseVersion: 2, steps: steps } }, as: :json

    step = response.parsed_body.dig("aggregate", "steps", 0)
    assert_equal({ "pageSize" => 1, "filter" => { "teamId" => "x" } }, step.dig("kind_config", "arguments"))
    assert_equal "r.json", step.dig("kind_config", "output_name")
    assert_equal "a", step["step_name"]
    assert_equal 2, response.parsed_body.dig("aggregate", "base_version")
  end

  test "an arguments key outside a kind config is still underscored" do
    post :create, params: { other: { arguments: { pageSize: 1 } } }, as: :json

    assert_equal({ "page_size" => 1 }, response.parsed_body.dig("other", "arguments"))
  end
end

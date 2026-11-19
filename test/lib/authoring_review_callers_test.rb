# frozen_string_literal: true

require "test_helper"

# Approving, rejecting and stamping are the web UI's alone. Tools (the Builder toolset, personal
# MCP handlers) may only call propose!.
class AuthoringReviewCallersTest < ActiveSupport::TestCase
  RESTRICTED = /Authoring::Review\.(approve!|reject!|stamp_web!)/

  test "only web controllers call approve!, reject! or stamp_web!" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].reject do |path|
      path.include?("/app/controllers/web/") || path.end_with?("app/services/authoring/review.rb")
    end.select { |path| File.read(path).match?(RESTRICTED) }

    assert_empty offenders.map { |path| Pathname(path).relative_path_from(Rails.root).to_s }
  end
end

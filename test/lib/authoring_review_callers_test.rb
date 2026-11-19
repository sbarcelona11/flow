# frozen_string_literal: true

require "test_helper"

# Approving, rejecting and stamping are the web UI's alone. Tools (the Builder toolset, personal
# MCP handlers) may only call propose!.
class AuthoringReviewCallersTest < ActiveSupport::TestCase
  METHODS = %w[approve! reject! stamp_web!].freeze
  # `Review.approve!` / `Authoring::Review.approve!` (any qualification, so the bare form inside
  # `module Authoring` counts), and the reflective forms with a symbol or string name.
  DIRECT = /\bReview\s*\.\s*(?:#{METHODS.map { |m| Regexp.escape(m) }.join('|')})/
  REFLECTIVE = /\b(?:send|public_send|__send__|method)\s*\(?\s*[:"'](?:#{METHODS.map { |m| Regexp.escape(m) }.join('|')})/
  ROOTS = %w[app lib config db].freeze
  EXTENSIONS = %w[rb rake erb ru].freeze
  ALLOWED_PREFIX = "app/controllers/web/"
  DEFINITION = "app/services/authoring/review.rb"

  def offenders
    ROOTS.flat_map { |root| Dir[Rails.root.join("#{root}/**/*.{#{EXTENSIONS.join(',')}}")] }.filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next if relative.start_with?(ALLOWED_PREFIX) || relative == DEFINITION

      text = File.read(path)
      relative if text.match?(DIRECT) || text.match?(REFLECTIVE)
    end
  end

  test "only web controllers call approve!, reject! or stamp_web!" do
    assert_empty offenders
  end

  test "the scan sees the forms it is meant to catch" do
    [ "Authoring::Review.approve!(x)", "Review.reject!(x)", "Review .stamp_web!(x)", "Authoring::Review.send(:approve!, x)",
      "Authoring::Review.public_send(\"reject!\", x)", "klass.send :stamp_web!, x" ].each do |source|
      assert source.match?(DIRECT) || source.match?(REFLECTIVE), source
    end
    assert_not "Authoring::Review.propose!(x)".match?(DIRECT)
  end
end

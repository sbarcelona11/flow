# frozen_string_literal: true

require "test_helper"

# Approving, rejecting and stamping are the web UI's alone. Tools (the Builder toolset, personal
# MCP handlers) may only call propose!.
class AuthoringReviewCallersTest < ActiveSupport::TestCase
  METHODS = %w[approve! reject! stamp_web! web_reviewer].freeze
  # `Review.approve!` / `Authoring::Review.approve!` (any qualification, so the bare form inside
  # `module Authoring` counts), and the reflective forms with a symbol or string name.
  DIRECT = /\bReview\s*\.\s*(?:#{METHODS.map { |m| Regexp.escape(m) }.join('|')})/
  REFLECTIVE = /\b(?:send|public_send|__send__|method)\s*\(?\s*[:"'](?:#{METHODS.map { |m| Regexp.escape(m) }.join('|')})/
  TOKEN = /\bWebReviewer\b/
  ROOTS = %w[app lib config db].freeze
  EXTENSIONS = %w[rb rake erb ru].freeze
  ALLOWED_PREFIX = "app/controllers/web/"
  DEFINITION = "app/services/authoring/review.rb"

  # Writing the review columns, or marking a row as made on the web, is what makes a record "reviewed by a person". Only the
  # web controllers and Authoring::Review do it. Allowed besides those: migrations (the backfill) and schema.rb, and
  # every file under test/ and spec/ (factories stamp rows) because this scan only reads app, lib, config and db.
  REVIEW_WRITE = /\breviewed_(?:at|by|by_id)\s*(?:=(?![=~])|:\s*(?!nil\b)[A-Za-z_@])|\borigin(?:\s*:\s*|\s*=\s*|"\s*=>\s*)"web"/
  WRITE_ALLOWED = [ "db/migrate/", "db/schema.rb" ].freeze

  def review_write_offenders
    ROOTS.flat_map { |root| Dir[Rails.root.join("#{root}/**/*.{#{EXTENSIONS.join(',')}}")] }.filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next if relative.start_with?(ALLOWED_PREFIX, *WRITE_ALLOWED) || relative == DEFINITION

      relative if File.read(path).match?(REVIEW_WRITE)
    end
  end

  def offenders
    ROOTS.flat_map { |root| Dir[Rails.root.join("#{root}/**/*.{#{EXTENSIONS.join(',')}}")] }.filter_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      next if relative.start_with?(ALLOWED_PREFIX) || relative == DEFINITION

      text = File.read(path)
      relative if text.match?(DIRECT) || text.match?(REFLECTIVE) || text.match?(TOKEN)
    end
  end

  test "only web controllers call approve!, reject!, stamp_web! or web_reviewer" do
    assert_empty offenders
  end

  test "only web controllers and Authoring::Review write the review columns or origin web" do
    assert_empty review_write_offenders
  end

  test "the write scan sees the forms it is meant to catch and leaves reads alone" do
    [ "record.reviewed_at = Time.current", "update!(reviewed_at: Time.current)", "assign_attributes(origin: \"web\", reviewed_by: user)",
      "reviewed_by_id: user.id", "self.origin = \"web\"", "{ \"origin\" => \"web\" }" ].each { |source| assert_match REVIEW_WRITE, source }
    [ "where(reviewed_at: nil)", "reviewed_at.present?", "origin == \"web\"", "reviewed_at == other", "validates :origin" ].each do |source|
      assert_no_match REVIEW_WRITE, source
    end
  end

  test "the scan sees the forms it is meant to catch" do
    [ "Authoring::Review.approve!(x)", "Review.reject!(x)", "Review .stamp_web!(x)", "Authoring::Review.send(:approve!, x)",
      "Authoring::Review.public_send(\"reject!\", x)", "Authoring::Review.web_reviewer(user_session: s)", "Review.send(:web_reviewer, s)", "klass.send :stamp_web!, x" ].each do |source|
      assert source.match?(DIRECT) || source.match?(REFLECTIVE), source
    end
    [ "Authoring::Review::WebReviewer.send(:new, u, s)", "WebReviewer.allocate", "Marshal.load(Marshal.dump(WebReviewer))",
      "x.is_a?(Authoring::Review::WebReviewer)" ].each { |source| assert_match TOKEN, source }
    assert_not "Authoring::Review.propose!(x)".match?(DIRECT)
  end
end

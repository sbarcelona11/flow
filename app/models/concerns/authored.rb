# frozen_string_literal: true

# Provenance and review state for things people or tools author: who made it, through which
# door, and who looked at it before it could be used. The database holds the invariant
# (NOT enabled OR reviewed_at IS NOT NULL); this concern keeps the model from ever reaching it.
module Authored
  extend ActiveSupport::Concern

  ORIGINS = %w[web builder mcp].freeze

  included do
    belongs_to :created_by, class_name: "User", optional: true
    belongs_to :reviewed_by, class_name: "User", optional: true

    validates :origin, inclusion: { in: ORIGINS }
    validate :enabled_requires_review

    scope :awaiting_review, -> { where(reviewed_at: nil) }

    before_validation :review_web_rows_on_create, on: :create
    before_validation :hold_unreviewed_tool_rows
    before_create :review_web_rows_on_create
    before_save :hold_unreviewed_tool_rows
  end

  def reviewed? = reviewed_at.present?

  def review_state = reviewed? ? "reviewed" : "waiting"

  private

  # A row made through the model on the web path (seeds, tests, `save(validate: false)`, the controllers
  # before they stamp the person) counts as reviewed by its creator; a tool's row never does.
  def review_web_rows_on_create
    self.reviewed_at ||= Time.current if origin == "web"
  end

  def hold_unreviewed_tool_rows
    self.enabled = false if origin != "web" && reviewed_at.nil?
  end

  def enabled_requires_review
    errors.add(:enabled, "needs a review before it can be enabled") if enabled? && reviewed_at.nil?
  end
end

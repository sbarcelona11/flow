# frozen_string_literal: true

# Provenance and review state for things people or tools author: who made it, through which
# door, and who looked at it before it could be used. The database holds the invariants
# (NOT enabled OR reviewed_at IS NOT NULL; a rejected row is never enabled); this concern keeps
# the model from ever reaching them, and fails closed: `origin` has no default, and nothing here
# stamps a row as reviewed. Only Authoring::Review does that.
module Authored
  extend ActiveSupport::Concern

  ORIGINS = %w[web builder mcp].freeze

  included do
    belongs_to :created_by, class_name: "User", optional: true
    belongs_to :reviewed_by, class_name: "User", optional: true
    belongs_to :rejected_by, class_name: "User", optional: true

    validates :origin, inclusion: { in: ORIGINS, message: "must be one of #{ORIGINS.join(', ')}" }
    validate :enabled_requires_review
    validate :rejected_is_never_enabled

    scope :awaiting_review, -> { where(reviewed_at: nil, rejected_at: nil) }

    before_validation :hold_new_tool_rows, on: :create
    before_create :hold_new_tool_rows
  end

  def reviewed? = reviewed_at.present?

  def rejected? = rejected_at.present?

  def review_state
    return "rejected" if rejected?

    reviewed? ? "reviewed" : "waiting"
  end

  private

  # A tool's new row is a proposal, so it is saved disabled whatever it asked for. An update that
  # asks to enable an unreviewed row is not coerced: it fails validation.
  def hold_new_tool_rows
    self.enabled = false if origin != "web" && reviewed_at.nil?
  end

  def enabled_requires_review
    errors.add(:enabled, "needs a review before it can be enabled") if enabled? && reviewed_at.nil?
  end

  def rejected_is_never_enabled
    errors.add(:enabled, "can't be enabled after a rejection") if enabled? && rejected?
  end
end

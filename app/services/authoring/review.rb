# frozen_string_literal: true

module Authoring
  # The one place a connector, operation or module moves between "proposed" and "reviewed".
  # Tools propose; only a person approves. Every transition writes an Audit row in the same
  # transaction as the change.
  class Review
    class AlreadyReviewed < StandardError; end
    class Archived < StandardError; end

    AUDIT_ACTIONS = { proposed: "authoring.proposed", approved: "authoring.approved", rejected: "authoring.rejected" }.freeze
    TOOL_ORIGINS = (Authored::ORIGINS - [ "web" ]).freeze
    DIGEST_EXCLUDED = %w[id created_at updated_at].freeze

    class << self
      def stamp_web!(record, user)
        record.assign_attributes(origin: "web", created_by: user, reviewed_by: user, reviewed_at: Time.current)
        record
      end

      def propose!(record, user:, origin:, session: nil)
        raise ArgumentError, "a proposal comes from a tool: #{TOOL_ORIGINS.join(' or ')}" unless TOOL_ORIGINS.include?(origin)

        record.assign_attributes(origin: origin, created_by: user, origin_session_id: session&.id, enabled: false,
                                 reviewed_by: nil, reviewed_at: nil)
        transaction do
          record.save!
          audit!(record, :proposed, user)
        end
        record
      end

      def approve!(records, user:)
        person!(user)
        waiting = Array(records)
        transaction do
          waiting.each do |record|
            ensure_waiting!(record)
            raise Archived, "#{describe(record)} is archived" if record.respond_to?(:archived?) && record.archived?

            record.update!(reviewed_by: user, reviewed_at: Time.current, enabled: true)
            audit!(record, :approved, user)
          end
        end
        waiting
      end

      def reject!(records, user:)
        person!(user)
        waiting = Array(records)
        transaction do
          waiting.each do |record|
            ensure_waiting!(record)
            record.respond_to?(:archive!) ? record.archive! : record.update!(enabled: false)
            audit!(record, :rejected, user)
          end
        end
        waiting
      end

      private

      def transaction(&) = ApplicationRecord.transaction(&)

      def person!(user)
        raise ArgumentError, "a signed-in person is required" unless user.is_a?(User)
      end

      def ensure_waiting!(record)
        raise AlreadyReviewed, "#{describe(record)} was already reviewed" if record.reviewed?
      end

      def describe(record) = "#{record.class.name} #{record.id}"

      def project_of(record)
        owner = record.is_a?(ApiOperation) ? record.api_connector : record
        owner.scope
      end

      def audit!(record, event, user)
        Audit.create!(
          auditable: record, associated: project_of(record), user: user, username: user.email,
          action: AUDIT_ACTIONS.fetch(event), audited_changes: digest_of(record),
          comment: "#{user.email}: #{event} #{record.class.name.underscore.humanize.downcase} #{record.id}"
        )
      end

      def digest_of(record)
        { "type" => record.class.name, "origin" => record.origin, "session_id" => record.origin_session_id,
          "status" => record.review_state,
          "digest" => Digest::SHA256.hexdigest(record.attributes.except(*DIGEST_EXCLUDED).to_json) }
      end
    end
  end
end

# frozen_string_literal: true

module Authoring
  # The one place a connector, operation or module moves between "proposed", "reviewed" and
  # "rejected". Tools propose; only a person in a signed-in web session approves or rejects.
  # Every transition writes an Audit row in the same transaction as the change.
  class Review
    class AlreadyReviewed < StandardError; end
    class Rejected < StandardError; end
    class Archived < StandardError; end
    class ContentChanged < StandardError; end
    class WrongProject < StandardError; end
    class ConnectorNotReviewed < StandardError; end

    AUDIT_ACTIONS = { proposed: "authoring.proposed", approved: "authoring.approved", rejected: "authoring.rejected",
                      archived: "authoring.archived", test_call: "rest.test_call",
                      secret_bound: "authoring.secret_bound" }.freeze
    ARGUMENT_DIGEST_PURPOSE = "rest test call arguments"
    TOOL_ORIGINS = (Authored::ORIGINS - [ "web" ]).freeze
    CONTENT_COLUMNS = {
      "ApiConnector" => %w[scope_type scope_id name base_url auth_type auth_config default_headers description],
      "ApiOperation" => %w[api_connector_id name http_method path summary description effect input_schema cost_cents],
      "ModuleDefinition" => %w[scope_type scope_id kind namespace slug version manifest]
    }.freeze

    class WebReviewer
      attr_reader :user, :user_session

      private_class_method :new

      def initialize(user, user_session)
        @user = user
        @user_session = user_session
        freeze
      end

      # The session is checked again here: a token minted before the person signed out must not stamp afterwards.
      def stamp!(record)
        Review.send(:live_session!, user_session)
        Review.stamp_web!(record, user)
      end

      def dup = raise(TypeError, "a reviewer can't be copied")
      def clone(**) = raise(TypeError, "a reviewer can't be copied")
    end

    class << self
      # What a reviewer saw: the content columns only, so the review state, enabled flag and
      # timestamps never change it. approve! takes it back as expected_digests.
      def digest_for(record)
        columns = CONTENT_COLUMNS.fetch(record.class.name)
        Digest::SHA256.hexdigest(canonical(record.attributes.slice(*columns)).to_json)
      end

      # Keyed, so an enumerable value (an id, an email, a date) cannot be recovered from the audit row by trying guesses.
      def arguments_digest(value)
        key = Rails.application.key_generator.generate_key(ARGUMENT_DIGEST_PURPOSE, 32)
        OpenSSL::HMAC.hexdigest("SHA256", key, canonical(value).to_json)
      end

      # One row per try of a read operation, whatever came of it. The arguments are kept as a keyed digest only, and the
      # answer not at all. The host and the Config Item NAMES say where a secret went.
      def record_test_call!(operation, user:, arguments:, status:, outcome:, host:, config_item_names: [], user_session: nil)
        person!(user)
        Audit.create!(
          auditable: operation, associated: project_of(operation), user: user, username: user.email,
          action: AUDIT_ACTIONS.fetch(:test_call), remote_address: user_session&.ip_address,
          audited_changes: { "type" => operation.class.name, "arguments_digest" => arguments_digest(arguments), "status" => status,
                             "outcome" => outcome, "host" => host, "config_item_names" => Array(config_item_names).sort },
          comment: "#{user.email}: tried read operation #{operation.id}"
        )
      end

      # The person confirmed which host each named Config Item goes to. Names and hosts only.
      def record_secret_confirmation!(record, user:, bindings:, user_session: nil)
        person!(user)
        Audit.create!(
          auditable: record, associated: project_of(record), user: user, username: user.email,
          action: AUDIT_ACTIONS.fetch(:secret_bound), remote_address: user_session&.ip_address,
          audited_changes: { "type" => record.class.name, "bindings" => bindings },
          comment: "#{user.email}: confirmed #{bindings.join(', ')}"
        )
      end

      # What the web controller hands to a service to create records as reviewed by the person at the keyboard. Only the
      # signed-in person's live cookie session mints it, so a tool, which holds a User and no UserSession, cannot.
      def reviewer_for?(reviewer, user)
        reviewer.is_a?(WebReviewer) && reviewer.user == user
      end

      def web_reviewer(user_session:)
        WebReviewer.send(:new, web_person!(user_session), user_session)
      end

      def stamp_web!(record, user)
        person!(user)
        record.assign_attributes(origin: "web", created_by: user, reviewed_by: user, reviewed_at: Time.current)
        record
      end

      def propose!(record, user:, origin:, session: nil)
        raise ArgumentError, "a proposal comes from a tool: #{TOOL_ORIGINS.join(' or ')}" unless TOOL_ORIGINS.include?(origin)
        raise ArgumentError, "a proposal is a new record; propose a new version instead" unless record.new_record?

        person!(user)
        record.assign_attributes(origin: origin, created_by: user, origin_session_id: session&.id, enabled: false,
                                 reviewed_by: nil, reviewed_at: nil, rejected_by: nil, rejected_at: nil)
        transaction do
          record.save!
          audit!(record, :proposed, user, nil)
        end
        record
      end

      # expected_digests: { record => digest_for(record) as the reviewer saw it }, one per record.
      def approve!(records, user_session:, project:, expected_digests:)
        user = web_person!(user_session)
        records = Array(records)
        check_project!(records, project)
        transaction do
          records.each do |record|
            lock_and_check!(record, project)
            expected = expected_digests.fetch(record) { raise ArgumentError, "no expected digest for #{describe(record)}" }
            raise ContentChanged, "#{describe(record)} changed after it was shown for review" unless digest_for(record) == expected

            ensure_connector_reviewed!(record)
            record.update!(reviewed_by: user, reviewed_at: Time.current, enabled: true)
            audit!(record, :approved, user, user_session)
          end
        end
        records
      end

      def reject!(records, user_session:, project:)
        user = web_person!(user_session)
        records = Array(records)
        check_project!(records, project)
        transaction do
          records.each do |record|
            lock_and_check!(record, project)
            attributes = { rejected_by: user, rejected_at: Time.current, enabled: false }
            attributes[:archived_at] = Time.current if record.respond_to?(:archive!)
            record.update!(attributes)
            audit!(record, :rejected, user, user_session)
          end
        end
        records
      end

      def archive!(record, user_session:, project:)
        user = web_person!(user_session)
        check_project!([ record ], project)
        transaction do
          record.lock!
          raise WrongProject, "#{describe(record)} belongs to another project" unless project_of(record) == project
          raise Archived, "#{describe(record)} is already archived" if record.archived?

          record.update!(archived_at: Time.current, enabled: false)
          audit!(record, :archived, user, user_session)
        end
        record
      end

      private

      def transaction(&) = ApplicationRecord.transaction(&)

      def person!(user)
        raise ArgumentError, "a signed-in person is required" unless user.is_a?(User)
      end

      # Only the cookie-backed session of the signed-in web user counts. Builder and MCP callers
      # hold a User, never a live UserSession.
      def web_person!(user_session)
        live_session!(user_session)
        user_session.user.tap { |user| person!(user) }
      end

      def live_session!(user_session)
        return if user_session.is_a?(UserSession) && user_session.persisted? && UserSession.live.exists?(user_session.id)

        raise ArgumentError, "approving and rejecting need a signed-in web session"
      end

      def check_project!(records, project)
        raise ArgumentError, "a project is required" unless project.is_a?(Project)

        records.each do |record|
          raise WrongProject, "#{describe(record)} belongs to another project" unless project_of(record) == project
        end
      end

      def lock_and_check!(record, project)
        record.lock!
        raise WrongProject, "#{describe(record)} belongs to another project" unless project_of(record) == project
        raise Rejected, "#{describe(record)} was rejected" if record.rejected?
        raise AlreadyReviewed, "#{describe(record)} was already reviewed" if record.reviewed?
        raise Archived, "#{describe(record)} is archived" if record.respond_to?(:archived?) && record.archived?
      end

      def ensure_connector_reviewed!(record)
        return unless record.is_a?(ApiOperation)

        connector = ApiConnector.find(record.api_connector_id)
        return if connector.reviewed? && !connector.archived?

        raise ConnectorNotReviewed, "#{describe(record)} belongs to a connector that is not approved"
      end

      def describe(record) = "#{record.class.name} #{record.id}"

      def project_of(record)
        owner = record.is_a?(ApiOperation) ? record.api_connector : record
        owner.scope
      end

      def audit!(record, event, user, user_session)
        impersonator = user_session&.impersonator
        changes = { "type" => record.class.name, "origin" => record.origin, "session_id" => record.origin_session_id,
                    "status" => record.review_state, "digest" => digest_for(record) }
        changes["impersonator_id"] = impersonator.id if impersonator
        Audit.create!(
          auditable: record, associated: project_of(record), user: user, username: user.email,
          action: AUDIT_ACTIONS.fetch(event), audited_changes: changes, remote_address: user_session&.ip_address,
          comment: "#{impersonator ? "#{impersonator.email} as " : ''}#{user.email}: #{event} " \
                   "#{record.class.name.underscore.humanize.downcase} #{record.id}"
        )
      end

      def canonical(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, inner| [ key.to_s, canonical(inner) ] }
        when Array then value.map { |inner| canonical(inner) }
        else value
        end
      end
    end
  end
end

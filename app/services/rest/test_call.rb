# frozen_string_literal: true

module Rest
  # Tries one read operation of a reviewed connector with the arguments a person typed. It is the same request
  # a run would make (same SSRF checks, same secrets, no redirects) but it has no step run, no approval and no
  # at-most-once record, so anything that is not a plain read is refused before a request is built. It is never
  # retried: one call, one audit row.
  class TestCall
    PREVIEW_BYTES = 64.kilobytes
    READ_TIMEOUT = 20
    DEADLINE = 20
    NOT_READ = "Only read operations can be tried here. Anything that writes runs inside a workflow, behind an approval."

    def self.run(...) = new(...).run

    # project: the project the caller works in. A service is handed an operation id by tools too, so the project is
    # checked here and not only by the controller's lookup.
    def initialize(operation:, arguments:, user:, project:, user_session: nil, origin: nil, origin_session_id: nil)
      @operation = operation
      @connector = operation.api_connector
      raise Authoring::Review::WrongProject, "that operation belongs to another project" unless @connector&.scope == project

      @arguments = arguments
      @user = user
      @user_session = user_session
      @origin = origin
      @origin_session_id = origin_session_id
    end

    def run
      refusal = refusal_reason
      return finish(refused(refusal), "refused") if refusal

      invalid = argument_error
      return finish(refused(invalid), "invalid_arguments") if invalid

      result = OperationCaller.call(operation: @operation, arguments: @arguments, project: @connector.scope,
                                    read_timeout: READ_TIMEOUT, deadline: DEADLINE)
      finish(answer(result), result.ok? ? "ok" : "failed", result.config_item_names)
    end

    private

    def refusal_reason
      return "Only a connector of a project can be tried." unless @connector&.scope_type == "Project"
      return NOT_READ unless @operation.effect == "read" && @operation.http_method == "GET"
      return "#{@connector.name} is archived." if @connector.archived?
      return "#{@connector.name} is waiting for review. Approve it before trying its operations." unless @connector.reviewed?
      return "#{@connector.name} is switched off." unless @connector.enabled?
      return "#{@operation.name} is waiting for review." unless @operation.reviewed?

      "#{@operation.name} is switched off." unless @operation.enabled?
    end

    def argument_error
      return "The arguments must be an object." unless @arguments.is_a?(Hash)

      schema = @operation.input_schema
      return nil unless schema.is_a?(Hash) && schema.any?

      unknown = @arguments.keys.map(&:to_s) - schema["properties"].to_h.keys
      return "#{unknown.first.to_s.first(64)} is not one of the arguments of #{@operation.name}." if unknown.any?

      first = JSONSchemer.schema(schema).validate(@arguments.deep_stringify_keys).first
      first && safe_message(first)
    rescue StandardError => e
      "The input schema of #{@operation.name} can't be read (#{e.class.name.demodulize})."
    end

    # json_schemer's message can quote what was typed, so only the top-level argument is named.
    def safe_message(error)
      argument = error["data_pointer"].to_s.split("/").reject(&:empty?).first
      argument ? "The value of #{argument.first(64)} does not fit its schema." : "The arguments do not fit the schema."
    end

    def refused(message) = { ok: false, status: nil, preview: nil, truncated: false, error: message }

    def answer(result)
      redact = result.redactor
      return { ok: false, status: result.status, preview: nil, truncated: false, error: redact.call(result.error.to_s) } unless result.ok?

      text = result.structured.nil? ? result.text.to_s : JSON.pretty_generate(result.structured)
      text = redact.call(text)
      truncated = text.bytesize > PREVIEW_BYTES
      text = text.byteslice(0, PREVIEW_BYTES).scrub("") if truncated
      { ok: true, status: result.status, preview: text, truncated: truncated, error: nil }
    end

    def finish(outcome, label, config_item_names = [])
      Authoring::Review.record_test_call!(@operation, user: @user, arguments: @arguments, status: outcome[:status], outcome: label,
                                                      host: @connector.host, config_item_names: config_item_names,
                                                      user_session: @user_session, origin: @origin,
                                                      origin_session_id: @origin_session_id)
      outcome
    end
  end
end

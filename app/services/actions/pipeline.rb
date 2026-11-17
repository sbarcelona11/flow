# frozen_string_literal: true

module Actions
  # Every action step runs through this one template, whatever its transport: the checks, the attempt mark, the
  # ActionCall, the outcome, the output and the redaction all happen here. A transport only makes the call and returns
  # a Connectors::Result, so it cannot skip a check or record anything itself.
  class Pipeline
    ERROR_LIMIT = 500
    REDACTED = "[redacted]"

    Refusal = Data.define(:category, :message)
    Attempt = Data.define(:transport, :connection, :operation, :arguments, :action_call, :tool_result)

    def self.start(step_run:, kind_config:, depends_on_step_ids:)
      new(step_run, kind_config).start(depends_on_step_ids)
    end

    def self.status(step_run:, handle:) = new(step_run, {}).status(handle)

    def self.finish(step_run:, handle:, stopped:, kind_config:)
      new(step_run, kind_config).finish(handle, stopped)
    end

    def initialize(step_run, kind_config)
      @step_run = step_run
      @config = kind_config.to_h
    end

    def start(depends_on)
      attempt = @step_run.with_lock { begin_attempt(depends_on) }
      return attempt if attempt.is_a?(Hash)

      attempt.transport.async? ? call_async(attempt) : call_sync(attempt)
    end

    def status(handle) = { "state" => transport_of(last_call).status(handle) }

    def finish(handle, stopped)
      tool_result = attempt_record(handle["tool_result_id"])
      action_call = last_call
      return close_stopped(tool_result, action_call, stopped) if stopped || outcome.terminal?(@step_run)

      { "outcome" => finish_async(tool_result, action_call)["outcome"] }
    end

    private

    def outcome = StepRunOutcome

    def effect = @config["effect"]

    def workflow_run = @step_run.workflow_run

    def project = workflow_run.project

    def last_call = ActionCall.where(step_run: @step_run).order(:id).last

    def transport_for(target)
      Connectors::Registry.for_target(target).new
    rescue Connectors::Registry::Unknown
      nil
    end

    def transport_of(action_call) = Connectors::Registry.for_target(action_call&.target_type).new

    def begin_attempt(depends_on)
      return outcome.done(@step_run) if outcome.terminal?(@step_run)
      return already_attempted if @step_run.action_attempted_at && effect != "read"

      checked = check(depends_on)
      return outcome.fail!(@step_run, checked.category, checked.message) if checked.is_a?(Refusal)

      now = Time.current
      @step_run.update!(action_attempted_at: now)
      @step_run.mark_running! unless @step_run.running?
      action_call = ActionCall.create!(step_run: @step_run, **call_attributes(checked.transport, checked.operation),
                                       arguments: checked.arguments, attempted_at: now)
      checked.with(action_call: action_call, tool_result: checked.transport.async? ? new_tool_result(checked) : nil)
    end

    def already_attempted
      label = transport_for(@config["target"])&.config_label(@config, project) || "the action's tool"
      message = "This action may already have run, so it was not sent again. Check #{label} before retrying."
      action_call = last_call || ActionCall.create!(step_run: @step_run, **call_attributes(transport_for(@config["target"])),
                                                    attempted_at: @step_run.action_attempted_at)
      action_call.finish!(outcome: "unknown", error: message) if action_call.outcome.nil?
      outcome.fail!(@step_run, :action_outcome_unknown, message)
    end

    def call_attributes(transport, operation = nil)
      { target_type: @config["target"], mcp_server_id: @config["mcp_server_id"],
        tool_name: transport&.recorded_name(@config, operation), tool_id: @config["tool_id"],
        api_operation_id: @config["api_operation_id"], effect: effect }
    end

    def new_tool_result(attempt)
      ToolResult.create!(tool: attempt.connection, step_run: @step_run, execution_id: ToolResult.generate_id,
                         state: "processing")
    end

    def check(depends_on)
      resolved = project && Catalog.new(project).resolve(@config)
      unless resolved && resolved.transport.scope_of(resolved.connection) == project
        return Refusal.new(:action_target_missing, "The action's tool is not available in this project.")
      end

      transport, connection, operation = resolved.transport, resolved.connection, resolved.operation
      return drifted(transport, connection, operation) if operation.drifted

      unless Effect.at_least?(effect, operation.base_effect)
        return Refusal.new(:action_failed, "The #{transport.operation_noun}'s own effect is now #{operation.base_effect}, " \
                                           "stricter than this step's #{effect}. Update the step before running it.")
      end
      if Effect.needs_approval?(effect) && !approved_in_run?(depends_on)
        return Refusal.new(:action_not_approved, "This action needs an approval that was given in this run.")
      end

      arguments = resolved_arguments(transport, operation)
      return arguments if arguments.is_a?(Refusal)

      Attempt.new(transport: transport, connection: connection, operation: operation, arguments: arguments,
                  action_call: nil, tool_result: nil)
    end

    def drifted(transport, connection, operation)
      Refusal.new(:action_tool_drifted, "#{operation.name} on #{transport.owner(connection)} changed since it was approved. " \
                                        "Review the change on the server page before running this step.")
    end

    def approved_in_run?(depends_on)
      approvals = Step.not_deleted.where(id: depends_on, kind: "approval").select(:id)
      workflow_run.step_runs.where(step_id: approvals, state: "completed").exists?
    end

    def resolved_arguments(transport, operation)
      arguments = Arguments.resolve(@config["arguments"] || {}, shared_context: workflow_run.shared_context)
      blocker = transport.action_blocker(operation.input_schema, arguments)
      return invalid_arguments(blocker) if blocker

      error = schema_error(operation.input_schema, arguments)
      error ? invalid_arguments("Arguments don't match the tool: #{error}") : arguments
    rescue Arguments::Missing => e
      invalid_arguments("The run's context has no value for #{e.key}.")
    end

    def schema_error(schema, arguments)
      return nil unless schema.is_a?(Hash) && schema.any?

      first = JSONSchemer.schema(schema).validate(arguments).first
      first && first["error"]
    rescue StandardError => e
      "its input schema can't be read (#{e.class.name.demodulize})"
    end

    def invalid_arguments(message) = Refusal.new(:action_invalid_arguments, message)

    def context(attempt)
      Connectors::Context.new(project: project, user: workflow_run.user, step_run_id: @step_run.id,
                              run_id: workflow_run.id, tool_result_id: attempt.tool_result&.id)
    end

    def make_call(attempt)
      attempt.transport.call(connection: attempt.connection, operation: attempt.operation, arguments: attempt.arguments,
                             context: context(attempt))
    end

    def label(attempt) = attempt.transport.label(attempt.connection, attempt.operation)

    # Only the transport's own, already-redacted strings are kept: an exception escaping it (a Faraday error, the MCP
    # gem's) may carry the request headers.
    def call_sync(attempt)
      label = label(attempt)
      result = make_call(attempt)
      attempt.action_call.update!(config_item_names: Array(result.config_item_names))
      return unknown(attempt, "#{result.error.to_s.chomp('.')}. #{outcome.unknown_advice(label)}") if result.unknown?
      return close(attempt, "failed", :action_failed, result.error.to_s) unless result.ok?

      outcome.complete!(@step_run, attempt.action_call, @config, payload(result), redact: result.redactor) do |call|
        "Called #{label} (#{effect}) in #{call.duration_ms} ms"
      end
    rescue ::MCP::ToolCaller::AuthRequired => e
      close(attempt, "failed", :action_auth_required, e.message)
    rescue ::ConfigItems::ReferenceResolver::Missing => e
      names = Array(attempt.action_call.config_item_names) | attempt.transport.missing_config_item_names(e)
      attempt.action_call.update!(config_item_names: names)
      close(attempt, "failed", :action_failed, "#{attempt.transport.owner(attempt.connection)} needs #{e.message}.")
    rescue StandardError => e
      unknown(attempt, "#{e.class.name} while calling #{label}. #{outcome.unknown_advice(label)}")
    end

    def call_async(attempt)
      result = make_call(attempt)
      return { "mode" => "async" }.merge(result.structured) if result.ok?
      return unknown(attempt, result.error.to_s) if result.unknown?

      attempt.tool_result.update!(state: "failed", error: "The container did not start")
      close(attempt, "failed", :action_failed, result.error.to_s)
    rescue StandardError
      unknown(attempt, "#{label(attempt)} may have started. Check it before retrying.")
    end

    def payload(result) = result.structured.nil? ? result.text.to_s : result.structured

    def unknown(attempt, message) = close(attempt, "unknown", :action_outcome_unknown, message)

    def close(attempt, call_outcome, category, message)
      @step_run.with_lock do
        attempt.action_call.finish!(outcome: call_outcome, error: message)
        outcome.fail!(@step_run, category, message)
      end
    end

    def attempt_record(id)
      id ? ToolResult.find_by!(id: id, step_run: @step_run) : ToolResult.where(step_run: @step_run).order(:id).last
    end

    # The step ended while the call ran: its result no longer becomes the step's, but the call is closed so it never
    # reads as still running.
    def close_stopped(tool_result, action_call, stopped)
      @step_run.with_lock do
        state = outcome.terminal?(@step_run) ? @step_run.state.to_s : stopped
        close_stopped_call(action_call, tool_result, state) if action_call && action_call.outcome.nil?
        { "outcome" => state }
      end
    end

    def close_stopped_call(action_call, tool_result, state)
      return action_call.finish!(outcome: "succeeded") if tool_result&.state == "completed"

      label = tool_result ? action_call.target_label : "the Wrapper"
      action_call.finish!(outcome: "unknown",
                          error: "The step ended as #{state} while #{label} ran. #{outcome.unknown_advice(label)}")
    end

    def finish_async(tool_result, action_call)
      return @step_run.with_lock { outcome.fail!(@step_run, :action_failed, "The Wrapper never started.") } unless tool_result && action_call

      label = action_call.target_label
      result = transport_of(action_call).finish({ "tool_result_id" => tool_result.id })
      redact = config_redactor(Array(result.config_item_names))
      return succeed(tool_result, action_call, label, result, redact) if result.ok?

      call_outcome, category, message = failure(result, label, redact)
      @step_run.with_lock do
        action_call.finish!(outcome: call_outcome, error: message) if action_call.outcome.nil?
        outcome.fail!(@step_run, category, message)
      end
    end

    def succeed(tool_result, action_call, label, result, redact)
      outcome.complete!(@step_run, action_call, @config, payload(result), redact: redact) do |call|
        "Called #{label} (#{effect}) in #{tool_result.duration_ms || call.duration_ms} ms"
      end
    end

    def failure(result, label, redact)
      return [ "failed", :action_failed, redact.call(result.error.to_s)[0, ERROR_LIMIT] ] unless result.unknown?

      [ "unknown", :action_outcome_unknown,
        "#{label} #{redact.call(result.error.to_s.truncate(ERROR_LIMIT))}. #{outcome.unknown_advice(label)}" ]
    end

    # An asynchronous call's config items reach its process as environment variables, so its own output may print them.
    def config_redactor(names)
      lambda do |text|
        next text if names.empty? || project.nil?

        values = ConfigItem.where(name: names, scope: [ project, project.company ]).filter_map(&:decrypted_value)
        values.select { |value| value.length >= 4 }.sort_by { |value| -value.length }
              .reduce(text) { |scrubbed, value| scrubbed.gsub(value, REDACTED) }
      end
    end
  end
end

# frozen_string_literal: true

module Activities
  module Workflow
    class StartActionActivity < ::Activities::Base
      DEADLINE_MARGIN_SECONDS = 120

      Refusal = Struct.new(:category, :message)
      Attempt = Struct.new(:target, :subject, :arguments, :action_call, :tool_result)

      def execute(input)
        step_run = StepRun.find(input["step_run_id"])
        config = input["kind_config"] || step_run.step.kind_config

        depends_on = input["depends_on_step_ids"] || step_run.step.depends_on_step_ids
        attempt = step_run.with_lock { begin_attempt(step_run, config, depends_on) }
        return attempt if attempt.is_a?(Hash)

        attempt.target.type == "wrapper" ? start_wrapper(step_run, attempt) : call_mcp(step_run, config, attempt)
      end

      private

      def outcome = ::Actions::StepRunOutcome

      def begin_attempt(step_run, config, depends_on)
        return outcome.done(step_run) if outcome.terminal?(step_run)
        return already_attempted(step_run, config) if step_run.action_attempted_at && config["effect"] != "read"

        checked = check(step_run, config, depends_on)
        return outcome.fail!(step_run, checked.category, checked.message) if checked.is_a?(Refusal)

        target, subject, arguments = checked
        now = Time.current
        step_run.update!(action_attempted_at: now)
        step_run.mark_running! unless step_run.running?
        action_call = ActionCall.create!(step_run: step_run, **outcome.call_attributes(config), arguments: arguments,
                                         attempted_at: now)
        tool_result = target.type == "wrapper" ? new_tool_result(step_run, subject) : nil
        Attempt.new(target, subject, arguments, action_call, tool_result)
      end

      def already_attempted(step_run, config)
        label = outcome.label(step_run.workflow_run.project, config)
        message = "This action may already have run, so it was not sent again. Check #{label} before retrying."
        action_call = ActionCall.where(step_run: step_run).order(:id).last ||
                      ActionCall.create!(step_run: step_run, **outcome.call_attributes(config),
                                         attempted_at: step_run.action_attempted_at)
        action_call.finish!(outcome: "unknown", error: message) if action_call.outcome.nil?
        outcome.fail!(step_run, :action_outcome_unknown, message)
      end

      def check(step_run, config, depends_on)
        workflow_run = step_run.workflow_run
        project = workflow_run.project
        target = project && ::Actions::Catalog.new(project).find(config)
        subject = target && owned_subject(target, project)
        return Refusal.new(:action_target_missing, "The action's tool is not available in this project.") unless subject
        return drifted(target) if target.drifted

        effect = config["effect"]
        unless ::Actions::Effect.at_least?(effect, target.base_effect)
          return Refusal.new(:action_failed, "The tool's own effect is now #{target.base_effect}, stricter than this " \
                                             "step's #{effect}. Update the step before running it.")
        end
        if ::Actions::Effect.needs_approval?(effect) && !approved_in_run?(step_run, depends_on)
          return Refusal.new(:action_not_approved, "This action needs an approval that was given in this run.")
        end

        arguments = resolved_arguments(config, target, workflow_run)
        arguments.is_a?(Refusal) ? arguments : [ target, subject, arguments ]
      end

      def owned_subject(target, project)
        subject = target.type == "wrapper" ? Tool.find_by(id: target.tool_id) : MCPServer.find_by(id: target.mcp_server_id)
        subject if subject&.scope == project
      end

      def drifted(target)
        Refusal.new(:action_tool_drifted, "#{target.tool} on #{target.server_name} changed since it was approved. " \
                                          "Review the change on the server page before running this step.")
      end

      def approved_in_run?(step_run, depends_on)
        approvals = Step.not_deleted.where(id: depends_on, kind: "approval").select(:id)
        step_run.workflow_run.step_runs.where(step_id: approvals, state: "completed").exists?
      end

      def resolved_arguments(config, target, workflow_run)
        arguments = ::Actions::Arguments.resolve(config["arguments"] || {}, shared_context: workflow_run.shared_context)
        return invalid_arguments("Wrappers that use a repository can't run as actions.") if repository_bound?(target, arguments)

        error = schema_error(target.input_schema, arguments)
        error ? invalid_arguments("Arguments don't match the tool: #{error}") : arguments
      rescue ::Actions::Arguments::Missing => e
        invalid_arguments("The run's context has no value for #{e.key}.")
      end

      def repository_bound?(target, arguments)
        return false unless target.type == "wrapper"

        target.input_schema.to_h.fetch("properties", {}).to_h.key?(::Actions::TargetCheck::REPOSITORY_PARAMETER) ||
          arguments.key?(ContainerStrategies::CustomToolStrategy::REPOSITORY_REFERENCE)
      end

      def schema_error(schema, arguments)
        return nil unless schema.is_a?(Hash) && schema.any?

        first = JSONSchemer.schema(schema).validate(arguments).first
        first && first["error"]
      rescue StandardError => e
        "its input schema can't be read (#{e.class.name.demodulize})"
      end

      def invalid_arguments(message) = Refusal.new(:action_invalid_arguments, message)

      def new_tool_result(step_run, tool)
        ToolResult.create!(tool: tool, step_run: step_run, execution_id: ToolResult.generate_id, state: "processing")
      end

      # Only the caller's own, already-redacted strings are kept: an exception
      # escaping it (a Faraday error, the MCP gem's) may carry the request headers.
      def call_mcp(step_run, config, attempt)
        label = outcome.label_for(attempt.target)
        result = ::MCP::ToolCaller.call(server: attempt.subject, tool: attempt.target.tool, arguments: attempt.arguments,
                                        user: step_run.workflow_run.user)
        attempt.action_call.update!(config_item_names: Array(result.config_item_names))
        return unknown(step_run, attempt, "#{result.error.to_s.chomp('.')}. #{outcome.unknown_advice(label)}") if result.unknown?
        return finish(step_run, attempt, "failed", :action_failed, result.error.to_s) unless result.ok?

        payload = result.structured.nil? ? result.text.to_s : result.structured
        outcome.complete!(step_run, attempt.action_call, config, payload, redact: result.redactor) do |call|
          "Called #{label} (#{config['effect']}) in #{call.duration_ms} ms"
        end
      rescue ::MCP::ToolCaller::AuthRequired => e
        finish(step_run, attempt, "failed", :action_auth_required, e.message)
      rescue ::ConfigItems::ReferenceResolver::Missing => e
        finish(step_run, attempt, "failed", :action_failed, "#{attempt.subject.name} needs #{e.message}.")
      rescue StandardError => e
        unknown(step_run, attempt, "#{e.class.name} while calling #{label}. #{outcome.unknown_advice(label)}")
      end

      def unknown(step_run, attempt, message) = finish(step_run, attempt, "unknown", :action_outcome_unknown, message)

      def finish(step_run, attempt, call_outcome, category, message)
        step_run.with_lock do
          attempt.action_call.finish!(outcome: call_outcome, error: message)
          outcome.fail!(step_run, category, message)
        end
      end

      # TemporalService answers every Temporalio::Error, a deadline after the
      # server accepted the start included, with ok: false and its error_class;
      # only an answer without one (Temporal disabled) proves nothing was queued.
      # The fixed workflow id makes a second start a rejected duplicate.
      def start_wrapper(step_run, attempt)
        timeout = ContainerStrategies::ToolStrategy::DEFAULT_TIMEOUT
        execution = { parameters: attempt.arguments, project: step_run.workflow_run.project, session: nil,
                      timeout: timeout, tool_result_id: attempt.tool_result.id }
        begin
          manifest = attempt.subject.container_manifest(**execution)
        rescue StandardError => e
          return not_prepared(step_run, attempt, e)
        end
        started = attempt.subject.start_container_execution(**execution, manifest: manifest,
                                                            workflow_id: "action-step-run-#{step_run.id}")
        return not_started(step_run, attempt) if started.is_a?(Hash) && !started[:ok] && started[:error_class].nil?
        return maybe_started(step_run, attempt) unless started.is_a?(Hash) && started[:ok]

        { "mode" => "async", "tool_result_id" => attempt.tool_result.id,
          "deadline_seconds" => timeout + DEADLINE_MARGIN_SECONDS }
      rescue StandardError
        maybe_started(step_run, attempt)
      end

      def not_prepared(step_run, attempt, error)
        attempt.tool_result.update!(state: "failed", error: "The container did not start")
        finish(step_run, attempt, "failed", :action_failed,
               "#{error.class.name} while preparing #{outcome.label_for(attempt.target)}")
      end

      def not_started(step_run, attempt)
        attempt.tool_result.update!(state: "failed", error: "The container did not start")
        finish(step_run, attempt, "failed", :action_failed, "#{outcome.label_for(attempt.target)} could not start.")
      end

      def maybe_started(step_run, attempt)
        unknown(step_run, attempt, "#{outcome.label_for(attempt.target)} may have started. Check it before retrying.")
      end
    end
  end
end

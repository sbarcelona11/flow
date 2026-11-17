# frozen_string_literal: true

module Actions
  # How an action step run ends, shared by the start and finish activities. A
  # step run that ended meanwhile (cancelled, skipped) keeps its state.
  module StepRunOutcome
    TERMINAL_STATES = %w[completed failed skipped cancelled].freeze

    module_function

    def terminal?(step_run) = TERMINAL_STATES.include?(step_run.state.to_s)

    def done(step_run) = { "mode" => "done", "outcome" => step_run.state.to_s }

    def fail!(step_run, category, message)
      step_run.mark_failed!(message, error_category: category) unless terminal?(step_run)
      done(step_run)
    end

    class OutputNotSaved < StandardError; end

    def complete!(step_run, action_call, config, payload)
      action_call.finish!(outcome: "succeeded")
      step_run.with_lock do
        next done(step_run) if terminal?(step_run)

        begin
          OutputWriter.write!(step_run: step_run, name: config["output_name"].presence || Step::ACTION_DEFAULT_OUTPUT_NAME,
                              payload: payload)
        rescue OutputWriter::TooLarge => e
          next fail!(step_run, :action_output_too_large, "The tool's output is too large to keep: #{e.message}.")
        rescue StandardError
          raise OutputNotSaved
        end
        step_run.update!(step_note: yield(action_call))
        step_run.mark_completed!
        done(step_run)
      end
    rescue OutputNotSaved
      step_run.with_lock { fail!(step_run, :action_failed, "The tool ran, but its output could not be saved.") }
    end

    def call_attributes(config)
      { target_type: config["target"], mcp_server_id: config["mcp_server_id"], tool_name: config["tool"],
        tool_id: config["tool_id"], effect: config["effect"] }
    end

    def label_for(target)
      target.type == "wrapper" ? target.name : "#{target.server_name} · #{target.tool}"
    end

    def label(project, config)
      if config["target"] == "wrapper"
        tool = project && Tool.for_project(project).find_by(id: config["tool_id"])
        return tool ? tool.display_name.presence || tool.name : "the Wrapper"
      end

      server = project && MCPServer.for_project(project).find_by(id: config["mcp_server_id"])
      "#{server&.name || 'the server'} · #{config['tool']}"
    end

    def unknown_advice(label) = "This action may have run. Check #{label} before retrying."
  end
end

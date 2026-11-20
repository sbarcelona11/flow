# frozen_string_literal: true

module Modules
  module Composite
    # What Manifest checks about a composite's graph beyond its shape. Everything is bounded by the schema (at most
    # MAX_STEPS steps, 32 ports), so these walks are small.
    class GraphCheck
      BLOCKING_APPROVAL_DEFAULT = "fail"
      WORDS = /[^\s=:,;"'<>()\[\]{}]+/
      BEARER = /\b(?:Bearer|Basic)\s+\S{8,}/
      PROVIDER_KEY = %r{
        \A(?:glpat|shpat|npm|dop_v1|hf|rk_live|sk_live|pk_live)[-_][A-Za-z0-9_-]{16,}\z | \Agithub_pat_[A-Za-z0-9_]{20,}\z |
        \ASG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{8,}\z | \Axapp-[A-Za-z0-9-]{16,}\z | \AAIza[0-9A-Za-z_-]{20,}\z
      }x
      AUTH_NAME = /(?:\A|[-_.])(?:authorization|auth|api[-_]?key|apikey|bearer)\z|(?:key|token|secret|password|passwd|credential)s?\z/i
      ENTROPY_MIN_LENGTH = 32
      ENTROPY_MIN_BITS = 4.2

      def self.errors(data) = new(data).errors

      def initialize(data)
        @steps = data.dig("graph", "steps") || []
        @in_ports = (data.dig("ports", "in") || {}).keys
        @out_ports = data.dig("ports", "out") || {}
        @by_key = @steps.index_by { |step| step["key"] }
      end

      # The first problem found, as a sentence, or nil.
      def errors
        [ :keys, :wrapper, :dependencies, :tokens, :out_ports, :governance, :credentials, :runtimes ].each do |check|
          problem = send(check)
          return problem if problem
        end
        nil
      end

      private

      def keys
        return "graph has more than #{MAX_STEPS} steps." if @steps.size > MAX_STEPS

        duplicate = @steps.map { |step| step["key"] }.tally.find { |_, count| count > 1 }
        duplicate && "graph step key #{duplicate.first} is used twice."
      end

      def wrapper
        wrapped = @steps.find { |step| step.dig("kind_config", "target") == "wrapper" }
        wrapped && "graph step #{wrapped['key']} is a Wrapper action, which a block can't hold (it can't read other steps' outputs)."
      end

      # `depends_on` names graph keys, or `port:<name>` for a dependency the user binds when inserting the block.
      def dependencies
        @steps.each do |step|
          graph_dependencies(step).each do |key|
            return "graph step #{step['key']} depends on itself." if key == step["key"]
            return "graph step #{step['key']} depends on #{key}, which is not in the graph." unless @by_key.key?(key)
          end
          port = port_dependencies(step).find { |name| !@in_ports.include?(name) }
          return "graph step #{step['key']} waits on port #{port}, which ports.in does not declare." if port
        end
        cycle = cycle_through
        cycle && "graph steps wait on each other (#{cycle})."
      end

      def graph_dependencies(step) = Array(step["depends_on"]).grep_v(/\Aport:/)

      def port_dependencies(step) = Array(step["depends_on"]).grep(/\Aport:/).map { |entry| entry.delete_prefix("port:") }

      def cycle_through
        state = {}
        visit = lambda do |key, trail|
          return trail + [ key ] if state[key] == :open
          return nil if state[key] == :done

          state[key] = :open
          graph_dependencies(@by_key[key]).each do |dep|
            found = visit.call(dep, trail + [ key ])
            return found if found
          end
          state[key] = :done
          nil
        end
        @steps.each do |step|
          found = visit.call(step["key"], [])
          return found.join(" -> ") if found
        end
        nil
      end

      def upstream(key, seen = Set.new)
        graph_dependencies(@by_key[key]).each { |dep| upstream(dep, seen) if seen.add?(dep) }
        seen
      end

      def tokens
        @steps.each do |step|
          problem = text_problem(step) || argument_problem(step) || other_strings_problem(step)
          return problem if problem
        end
        nil
      end

      def texts(step)
        [ step["instructions"] ] + Array(step["sub_steps"]).map { |sub| sub["instructions"] }
      end

      def text_problem(step)
        texts(step).compact.each do |text|
          problem = port_problem(step, text, whole: false) || graph_token_problem(step, text)
          return problem if problem
        end
        nil
      end

      def argument_problem(step)
        arguments = step.dig("kind_config", "arguments")
        return unless arguments

        Composite.each_string(arguments) do |text|
          whole = text.match(/\A\{\{port:([^{}\n]*)\}\}\z/)
          problem = port_problem(step, text, whole: true, allowed_whole: whole) || graph_token_problem(step, text)
          return problem if problem
        end
        nil
      end

      def other_strings_problem(step)
        loose = [ step["name"], step["kind_config"]&.except("arguments"), Array(step["sub_steps"]).map { |sub| sub["name"] } ]
        Composite.each_string(loose) do |text|
          return "graph step #{step['key']} has a {{port:…}} where only instructions and action arguments may." if text.match?(PORT_TOKEN)
        end
        nil
      end

      def port_problem(step, text, whole:, allowed_whole: nil)
        text.scan(PORT_TOKEN).flatten.each do |name|
          return "graph step #{step['key']} uses port #{name.inspect}, which is not a valid port name." unless name.match?(Manifest::PORT_NAME)
          return "graph step #{step['key']} uses port #{name}, which ports.in does not declare." unless @in_ports.include?(name)
        end
        return unless whole && text.match?(PORT_TOKEN) && !allowed_whole

        "graph step #{step['key']} has a {{port:…}} inside a longer argument; a port must be the whole value."
      end

      def graph_token_problem(step, text)
        text.scan(OUTPUT_TOKEN).each do |key, file|
          return "graph step #{step['key']} reads the output of #{key}, which is not in the graph." unless @by_key.key?(key)
          return "graph step #{step['key']} reads #{key}, which does not declare an output #{file}." unless Composite.output_names(@by_key[key]).include?(file)
          return "graph step #{step['key']} reads the output of #{key} without depending on it." unless upstream(step["key"]).include?(key)
        end
        text.scan(STEP_TOKEN).flatten.each do |key|
          return "graph step #{step['key']} names step #{key}, which is not in the graph." unless @by_key.key?(key)
        end
        nil
      end

      def out_ports
        @out_ports.each do |name, port|
          step = @by_key[port["step"]]
          return "ports.out.#{name} names step #{port['step']}, which is not in the graph." unless step
          return "ports.out.#{name} names output #{port['output']}, which #{port['step']} does not declare." unless Composite.output_names(step).include?(port["output"])
        end
        nil
      end

      # Mirrors Actions::Governance on the graph alone: a send or irreversible action must depend directly on an approval
      # that stops the run when no one approves, so the group never expands into a workflow Save would refuse.
      def governance
        approvals = @steps.select { |step| blocking_approval?(step) }.to_set { |step| step["key"] }
        offender = @steps.find do |step|
          step["kind"] == "action" && Actions::Effect.needs_approval?(step.dig("kind_config", "effect")) &&
            graph_dependencies(step).none? { |key| approvals.include?(key) }
        end
        return unless offender

        "graph step #{offender['key']} (#{offender.dig('kind_config', 'effect')}) must depend on an approval step inside the block " \
          "that stops the run when no one approves."
      end

      def blocking_approval?(step)
        step["kind"] == "approval" && step.dig("kind_config", "on_timeout").to_s.then { |v| v.empty? ? BLOCKING_APPROVAL_DEFAULT : v } == "fail" &&
          step.fetch("on_failure", "fail") == "fail"
      end

      def credentials
        @steps.each do |step|
          found = credential_in(step)
          return "graph step #{step['key']} must not carry credentials (found one at #{found})." if found
        end
        nil
      end

      def credential_in(step)
        Composite.each_string(step.except("key")) { |text| return "its text" if credential_text?(text) }
        arguments = step.dig("kind_config", "arguments")
        named = credential_named(arguments)
        named && "argument #{named}"
      end

      def credential_text?(text)
        text.match?(Manifest::CREDENTIAL_VALUE) || text.match?(BEARER) ||
          text.scan(WORDS).any? { |word| word.match?(Manifest::CREDENTIAL_VALUE) || word.match?(PROVIDER_KEY) }
      end

      # A long, dense, mixed-case-or-digit string with no placeholder is a pasted secret, whatever its argument is called.
      def high_entropy?(value)
        return false if value.length < ENTROPY_MIN_LENGTH || !value.match?(/\A[A-Za-z0-9_+\/=.-]+\z/) || !value.match?(/\d/) || !value.match?(/[A-Za-z]/)

        counts = value.each_char.tally
        bits = counts.values.sum { |n| p = n.fdiv(value.length); -p * Math.log2(p) }
        bits >= ENTROPY_MIN_BITS
      end

      def credential_named(value, name = nil)
        case value
        when Hash
          value.each do |key, item|
            found = credential_named(item, key.to_s)
            return found if found
          end
          nil
        when Array then value.lazy.filter_map { |item| credential_named(item, name) }.first
        when String
          placeholder = value.match?(/\A\{\{[^{}\n]*\}\}\z/)
          (name || "a value") if !placeholder && value.present? && (name&.match?(AUTH_NAME) || high_entropy?(value))
        end
      end

      def runtimes
        bad = @steps.find { |step| step["required_agent_runtime"] && !Step::SUPPORTED_AGENT_RUNTIMES.include?(step["required_agent_runtime"]) }
        bad && "graph step #{bad['key']} has a required_agent_runtime that is not one of: #{Step::SUPPORTED_AGENT_RUNTIMES.join(', ')}."
      end
    end
  end
end

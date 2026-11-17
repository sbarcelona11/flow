# frozen_string_literal: true

module Actions
  # The files an action's arguments name with `{{output:<step>:<name>}}`, read from the run's own outputs: what the latest
  # completed run of that step wrote under exactly that name. Reads storage, so Pipeline calls it before it takes the
  # step run's row lock. A file that can't be used is kept as a reason, never as content: the pipeline refuses with it
  # only if the step run is still to be attempted.
  module OutputInputs
    Loaded = Data.define(:text, :reason)

    module_function

    def references(arguments)
      refs = []
      each_string(arguments) { |text| refs.concat(InstructionReferences.scan(text).select { |ref| ref.type == "output" }) }
      refs
    end

    def load(workflow_run:, refs:)
      refs.select(&:valid?).uniq { |ref| key(ref) }.to_h { |ref| [ key(ref), read(workflow_run, ref) ] }
    end

    # The arguments with each string replaced by the block's result; Pipeline never calls it, it is how the copies and
    # translations of a workflow carry `{{output:…}}` tokens to the new step ids.
    def map_strings(value, &block)
      case value
      when String then yield value
      when Hash then value.transform_values { |item| map_strings(item, &block) }
      when Array then value.map { |item| map_strings(item, &block) }
      else value
      end
    end

    def key(ref) = [ ref.id, ref.name ]

    def read(workflow_run, ref)
      return unavailable("the step isn't saved yet") unless ref.id.match?(InstructionReferences::ID)

      step_run = workflow_run.step_runs.where(step_id: ref.id.to_i, state: "completed").order(:id).last
      return unavailable("the step hasn't completed in this run") unless step_run

      asset = workflow_run.workflow_run_assets.where(produced_by_step_run_id: step_run.id, name: ref.name).order(:id).last
      return unavailable("the step wrote no file with that name") unless asset

      text_of(asset)
    rescue StandardError
      unavailable("the file couldn't be read")
    end

    def text_of(asset)
      limit = Step::ACTION_OUTPUT_INPUT_MAX_BYTES
      too_large = unavailable("the file is over #{limit / 1.megabyte} MB")
      return too_large if asset.file_size.to_i > limit
      return unavailable("the file has no content") unless asset.file

      content = asset.file.open { |io| io.read(limit + 1) }.to_s
      return too_large if content.bytesize > limit

      content.force_encoding(Encoding::UTF_8)
      return unavailable("the file isn't UTF-8 text") if !content.valid_encoding? || content.include?("\0")

      Loaded.new(text: content, reason: nil)
    end

    def unavailable(reason) = Loaded.new(text: nil, reason: reason)

    def each_string(value, &block)
      case value
      when String then yield value
      when Hash then value.each_value { |item| each_string(item, &block) }
      when Array then value.each { |item| each_string(item, &block) }
      end
    end

    private_class_method :read, :text_of, :unavailable, :each_string
  end
end

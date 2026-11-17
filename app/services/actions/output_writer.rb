# frozen_string_literal: true

module Actions
  module OutputWriter
    class TooLarge < StandardError; end

    module_function

    def write!(step_run:, name:, payload:)
      content, content_type = encode(payload, name)
      if content.bytesize > Step::ACTION_OUTPUT_MAX_BYTES
        raise TooLarge, "#{name} is #{content.bytesize} bytes, over the #{Step::ACTION_OUTPUT_MAX_BYTES / 1.megabyte} MB limit"
      end

      workflow_run = step_run.workflow_run
      Tempfile.create([ "action_output_", File.extname(name) ], binmode: true) do |file|
        file.write(content)
        file.rewind
        workflow_run.workflow_run_assets.create!(
          name: name,
          produced_by_step_run: step_run,
          content_type: content_type || Marcel::MimeType.for(file, name: name),
          file_size: content.bytesize,
          s3_key: "workflow_runs/#{workflow_run.id}/steps/#{step_run.id}/#{name}",
          file: file
        )
      end
    end

    def encode(payload, name)
      case payload
      when Hash, Array then [ JSON.pretty_generate(payload), "application/json" ]
      when String then [ payload, nil ]
      else raise ArgumentError, "#{name}: output must be a Hash, an Array or a String, got #{payload.class}"
      end
    end

    private_class_method :encode
  end
end

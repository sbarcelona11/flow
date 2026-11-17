# frozen_string_literal: true

require "test_helper"

class Actions::OutputWriterTest < ActiveSupport::TestCase
  setup do
    @step_run = create(:step_run)
    @run = @step_run.workflow_run
  end

  test "writes a JSON asset linked to the step run" do
    asset = Actions::OutputWriter.write!(step_run: @step_run, name: "result.json", payload: { "id" => 7 })

    assert_equal [ asset ], @run.workflow_run_assets.to_a
    assert_equal @step_run, asset.produced_by_step_run
    assert_equal "application/json", asset.content_type
    assert_equal({ "id" => 7 }, JSON.parse(asset.file.read))
    assert_equal asset.file.size, asset.file_size
    assert_equal "workflow_runs/#{@run.id}/steps/#{@step_run.id}/result.json", asset.s3_key
  end

  test "writes a string payload as is" do
    asset = Actions::OutputWriter.write!(step_run: @step_run, name: "notes.md", payload: "# Done")

    assert_equal "# Done", asset.file.read
    assert_equal 6, asset.file_size
  end

  test "refuses an output over 10 MB" do
    assert_raises(Actions::OutputWriter::TooLarge) do
      Actions::OutputWriter.write!(step_run: @step_run, name: "result.json", payload: "x" * (Step::ACTION_OUTPUT_MAX_BYTES + 1))
    end
    assert_empty @run.workflow_run_assets
  end
end

# frozen_string_literal: true

require "test_helper"

module Actions
  class PipelineOutputInputsTest < ActiveSupport::TestCase
    Connection = Data.define(:id, :name, :project)
    SCHEMA = { "type" => "object",
               "properties" => { "doc" => { "type" => "object" }, "note" => { "type" => "string" },
                                 "list" => { "type" => "array" } } }.freeze

    setup do
      @company = create(:company)
      @user = create(:user, company: @company)
      @project = create(:project, company: @company, owner: @user)
      @workflow = create(:workflow, scope: @project)
      @run = create(:workflow_run, :running, project: @project, workflow: @workflow, user: @user)
      @producer = create(:step, workflow: @workflow, name: "Fetch")
      @calls = []
      register_probe
    end

    teardown { Connectors::Registry.reset! }

    def register_probe(base_effect: "write", &on_call)
      connection = Connection.new(id: 7, name: "Probe", project: @project)
      calls = @calls
      operation = Connectors::Operation.new(key: "ping", name: "ping", description: nil, input_schema: SCHEMA, output_schema: nil,
                                            base_effect: base_effect, drifted: false)
      probe = Class.new(Connectors::Transport) do
        transport :output_inputs_probe, target: "output_inputs_probe_operation"

        define_method(:async?) { false }
        define_method(:scope_of) { |c| c.project }
        define_method(:connections) { |project| project == connection.project ? [ connection ] : [] }
        define_method(:connection_for) { |config, project| connections(project).find { |c| c.id == config["probe_id"] } }
        define_method(:operations) { |_connection| [ operation ] }
        define_method(:owner) { |c| c&.name }
        define_method(:label) { |c, op| "#{owner(c)} · #{op.name}" }
        define_method(:call) do |connection:, operation:, arguments:, context:|
          calls << { arguments: arguments }
          on_call&.call
          Connectors::Result.new(ok: true, structured: { "pong" => true })
        end
      end
      Connectors::Registry.reset!
      Connectors::Registry.stubs(:discovered_transports).returns([ probe ])
    end

    def config(arguments, effect: "write")
      { "target" => "output_inputs_probe_operation", "probe_id" => 7, "arguments" => arguments, "effect" => effect }
    end

    def token(name, step: @producer) = "{{output:#{step.id}:#{name}}}"

    def produce(name, content, step: @producer, state: :completed)
      run = @run.step_runs.where(step: step, state: state).first || create(:step_run, workflow_run: @run, step: step, state: state)
      OutputWriter.write!(step_run: run, name: name, payload: content)
    end

    def new_run = create(:step_run, workflow_run: @run, step: create(:step, workflow: @workflow))

    def start(step_run, config, depends_on: []) = Pipeline.start(step_run: step_run, kind_config: config, depends_on_step_ids: depends_on)

    def assert_refused(run, message)
      run.reload
      assert_equal [ "failed", "action_invalid_arguments", message ], [ run.state, run.error_category, run.error_message ]
      assert_nil run.action_attempted_at
      assert_equal 0, ActionCall.count
      assert_empty @calls
    end

    def unavailable(name, reason) = "The output #{name} of Fetch isn't available: #{reason}."

    test "a whole-value token of a .json output becomes the parsed value" do
      produce("doc.json", { "id" => 7, "tags" => [ "a" ] })
      run = new_run

      start(run, config({ "doc" => token("doc.json") }))

      assert_equal [ { "doc" => { "id" => 7, "tags" => [ "a" ] } } ], @calls.pluck(:arguments)
      assert_equal "completed", run.reload.state
    end

    test "a .json whole value can be any JSON type" do
      produce("list.json", [ 1, "two", nil ])

      start(new_run, config({ "list" => token("list.json") }))

      assert_equal [ [ 1, "two", nil ] ], @calls.pluck(:arguments).map { |arguments| arguments["list"] }
    end

    test "a whole-value token of any other output is its UTF-8 text" do
      produce("summary.md", "# Done\n{\"a\": 1}")

      start(new_run, config({ "note" => token("summary.md") }))

      assert_equal [ "# Done\n{\"a\": 1}" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
    end

    test "a token inside a longer string is interpolated, a .json output as compact JSON" do
      produce("doc.json", { "id" => 7 })
      produce("summary.md", "ready")
      @run.update!(shared_context: { "who" => "Ana" })

      start(new_run, config({ "note" => "#{token('summary.md')} for {{context:who}}: #{token('doc.json')}" }))

      assert_equal [ "ready for Ana: {\"id\":7}" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
    end

    test "tokens inside nested arguments resolve too" do
      produce("summary.md", "ready")

      start(new_run, config({ "doc" => { "inner" => [ token("summary.md") ] } }))

      assert_equal [ { "inner" => [ "ready" ] } ], @calls.pluck(:arguments).map { |arguments| arguments["doc"] }
    end

    test "content that looks like a placeholder stays literal text" do
      produce("summary.md", "{{context:who}} and {{output:#{@producer.id}:doc.json}}")
      produce("doc.json", { "x" => "{{context:who}}" })
      @run.update!(shared_context: { "who" => "Ana" })

      start(new_run, config({ "note" => token("summary.md"), "doc" => token("doc.json") }))
      start(new_run, config({ "note" => "see #{token('summary.md')}" }))

      whole, inline = @calls.pluck(:arguments)
      assert_equal "{{context:who}} and {{output:#{@producer.id}:doc.json}}", whole["note"]
      assert_equal({ "x" => "{{context:who}}" }, whole["doc"])
      assert_equal "see {{context:who}} and {{output:#{@producer.id}:doc.json}}", inline["note"]
    end

    test "a context value that looks like an output token is not read as one" do
      @run.update!(shared_context: { "who" => token("summary.md") })
      produce("summary.md", "secret")

      start(new_run, config({ "note" => "{{context:who}}" }))
      start(new_run, config({ "note" => "x {{context:who}}" }))

      assert_equal [ token("summary.md"), "x #{token('summary.md')}" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
    end

    test "the latest completed run of the step supplies the file" do
      produce("summary.md", "old")
      newer = create(:step_run, workflow_run: @run, step: @producer, state: :completed)
      OutputWriter.write!(step_run: newer, name: "summary.md", payload: "new")
      create(:step_run, workflow_run: @run, step: @producer, state: :failed)

      start(new_run, config({ "note" => token("summary.md") }))

      assert_equal [ "new" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
    end

    test "a step that has not run is refused before the attempt" do
      run = new_run

      start(run, config({ "note" => token("summary.md") }))

      assert_refused(run, unavailable("summary.md", "the step hasn't completed in this run"))
    end

    test "a step that is unfinished or failed is refused before the attempt" do
      %i[running failed].each do |state|
        step = create(:step, workflow: @workflow, name: "Fetch")
        produce("summary.md", "partial", step: step, state: state)
        run = new_run

        start(run, config({ "note" => token("summary.md", step: step) }))

        assert_equal "failed", run.reload.state
        assert_equal "action_invalid_arguments", run.error_category
        assert_includes run.error_message, "the step hasn't completed in this run"
        assert_nil run.action_attempted_at
      end
      assert_equal 0, ActionCall.count
      assert_empty @calls
    end

    test "a step that wrote no file of that name is refused" do
      produce("other.md", "x")
      run = new_run

      start(run, config({ "note" => token("summary.md") }))

      assert_refused(run, unavailable("summary.md", "the step wrote no file with that name"))
    end

    test "a step key that was never saved is refused" do
      run = new_run

      start(run, config({ "note" => "{{output:new-1:summary.md}}" }))

      assert_equal "action_invalid_arguments", run.reload.error_category
      assert_nil run.action_attempted_at
    end

    test "a binary file is refused without echoing it" do
      produce("blob.bin", "\xFF\xFEsecret-bytes".b)
      run = new_run

      start(run, config({ "note" => token("blob.bin") }))

      assert_refused(run, unavailable("blob.bin", "the file isn't UTF-8 text"))
    end

    test "a file over 1 MB is refused and one of exactly 1 MB is read" do
      produce("big.md", "a" * (1.megabyte + 1))
      produce("edge.md", "b" * 1.megabyte)
      refused = new_run

      start(refused, config({ "note" => token("big.md") }))
      assert_refused(refused, unavailable("big.md", "the file is over 1 MB"))

      start(new_run, config({ "note" => token("edge.md") }))
      assert_equal 1.megabyte, @calls.sole[:arguments]["note"].bytesize
    end

    test "a .json whole value that is not JSON is refused without echoing the file" do
      produce("doc.json", "{ nope TOPSECRET")
      run = new_run

      start(run, config({ "doc" => token("doc.json") }))

      assert_refused(run, unavailable("doc.json", "the file isn't valid JSON"))
      assert_not_includes run.error_message, "TOPSECRET"
    end

    test "a number out of range is refused whole-value and inline, before the attempt" do
      produce("doc.json", '{"n": 1e400}')
      whole = new_run
      inline = new_run

      start(whole, config({ "doc" => token("doc.json") }))
      assert_refused(whole, unavailable("doc.json", "the file has a number that is out of range"))
      start(inline, config({ "note" => "x #{token('doc.json')}" }))
      assert_equal "action_invalid_arguments", inline.reload.error_category
      assert_nil inline.action_attempted_at
      assert_empty @calls
    end

    test "JSON nested too deeply gets its own reason" do
      produce("doc.json", ("[" * 200) + ("]" * 200))
      run = new_run

      start(run, config({ "doc" => token("doc.json") }))

      assert_refused(run, unavailable("doc.json", "the file is nested too deeply"))
    end

    test "a storage error is raised for a retry instead of refusing the step" do
      produce("summary.md", "ready")
      run = new_run
      OutputInputs.stubs(:text_of).raises(Errno::ECONNRESET)

      assert_raises(Errno::ECONNRESET) { start(run, config({ "note" => token("summary.md") })) }

      assert_equal "pending", run.reload.state
      assert_nil run.action_attempted_at
    end

    test "a schema error on a value from a file names no key of the file" do
      produce("doc.json", { "SECRETKEY" => 1 })
      run = new_run

      start(run, config({ "doc" => token("doc.json") }.merge("note" => 5)))
      assert_not_includes run.reload.error_message, "SECRETKEY"

      other = new_run
      OutputInputs.unstub(:text_of)
      start(other, config({ "doc" => token("doc.json") }.merge("list" => "no")))
      assert_not_includes other.reload.error_message.to_s, "SECRETKEY"
    end

    test "a Wrapper action is refused at run time before any read or attempt" do
      tool = create(:tool, scope: @project)
      run = new_run
      OutputInputs.expects(:load).never

      start(run, { "target" => "wrapper", "tool_id" => tool.id, "effect" => "write",
                   "arguments" => { "m" => token("summary.md") } })

      run.reload
      assert_equal [ "failed", "action_invalid_arguments", Pipeline::WRAPPER_OUTPUTS ], [ run.state, run.error_category, run.error_message ]
      assert_nil run.action_attempted_at
      assert_equal 0, ActionCall.count
    end

    test "an interpolated string over 256 KB is refused" do
      produce("big.md", "a" * (Step::ACTION_ARGUMENT_STRING_MAX_BYTES + 1))
      run = new_run

      start(run, config({ "note" => "x #{token('big.md')}" }))

      assert_refused(run, unavailable("big.md", "the text it is part of would be over 256 KB"))
    end

    test "a token that cannot be read is refused" do
      run = new_run

      start(run, config({ "note" => "{{output:abc:x.md}}" }))

      assert_equal "action_invalid_arguments", run.reload.error_category
      assert_nil run.action_attempted_at
    end

    test "resolved values are validated against the operation's schema" do
      produce("doc.json", [ 1, 2 ])
      run = new_run

      start(run, config({ "doc" => token("doc.json") }))

      run.reload
      assert_equal "action_invalid_arguments", run.error_category
      assert_match(/\AArguments don't match the tool: /, run.error_message)
      assert_nil run.action_attempted_at
      assert_empty @calls
    end

    test "the content is kept nowhere: the step note and the call record only what they did before" do
      produce("summary.md", "TOPSECRET-CONTENT")
      run = new_run

      start(run, config({ "note" => token("summary.md") }))

      call = ActionCall.sole
      stored = [ run.reload.step_note, run.error_message, call.attributes.values.map(&:to_s) ].flatten.join(" ")
      assert_not_includes stored, "TOPSECRET"
      assert_equal ActionCall.digest({ "note" => "TOPSECRET-CONTENT" }), call.arguments_digest
    end

    test "a second start of an attempted write action ends as outcome unknown whatever the outputs are" do
      run = new_run
      run.update!(action_attempted_at: Time.current)
      ActionCall.create!(step_run: run, target_type: "output_inputs_probe_operation", effect: "write", attempted_at: run.action_attempted_at)
      OutputInputs.expects(:load).never

      start(run, config({ "note" => token("summary.md") }))

      run.reload
      assert_equal [ "failed", "action_outcome_unknown" ], [ run.state, run.error_category ]
      assert_empty @calls
    end

    test "a read action resolves its outputs again on every start" do
      produce("summary.md", "ready")
      register_probe(base_effect: "read") { raise Interrupt if @calls.one? }
      run = new_run
      read = config({ "note" => token("summary.md") }, effect: "read")
      loaded = OutputInputs.load(workflow_run: @run, refs: OutputInputs.references(read["arguments"]))
      OutputInputs.expects(:load).twice.returns(loaded)

      assert_raises(Interrupt) { start(run, read) }
      start(run, read)

      assert_equal [ "ready", "ready" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
      assert_equal "completed", run.reload.state
    end

    test "storage is read before the row lock is taken, once" do
      produce("summary.md", "ready")
      run = new_run
      probe = config({ "note" => token("summary.md") })
      loaded = OutputInputs.load(workflow_run: @run, refs: OutputInputs.references(probe["arguments"]))
      outside = ActiveRecord::Base.connection.open_transactions
      locked = run.with_lock { ActiveRecord::Base.connection.open_transactions }
      depths = []
      OutputInputs.stubs(:load).with { |**| depths << ActiveRecord::Base.connection.open_transactions }.returns(loaded)

      start(run, probe)

      assert_operator locked, :>, outside
      assert_equal [ outside ], depths
      assert_equal [ "ready" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
    end

    test "work the peek did not expect is read in a second round, outside the lock" do
      produce("summary.md", "ready")
      run = new_run
      probe = config({ "note" => token("summary.md") })
      loaded = OutputInputs.load(workflow_run: @run, refs: OutputInputs.references(probe["arguments"]))
      outside = ActiveRecord::Base.connection.open_transactions
      depths = []
      OutputInputs.stubs(:load).with { |**| depths << ActiveRecord::Base.connection.open_transactions }.returns(loaded)
      pipeline = Pipeline.new(run, probe)
      pipeline.stubs(:outputs_needed?).returns(false)

      pipeline.start([])

      assert_equal [ outside ], depths
      assert_equal [ "ready" ], @calls.pluck(:arguments).map { |arguments| arguments["note"] }
    end

    test "an action with no output tokens reads no storage" do
      OutputInputs.expects(:load).never

      start(new_run, config({ "note" => "plain {{context:who}}" }).merge("arguments" => { "note" => "plain" }))

      assert_equal 1, @calls.size
    end

    test "more tokens than the limit are refused" do
      args = (1..(Step::ACTION_OUTPUT_REFERENCES_MAX + 1)).to_h { |index| [ "k#{index}", token("a#{index}.md") ] }
      run = new_run

      start(run, config(args))

      assert_equal "action_invalid_arguments", run.reload.error_category
      assert_nil run.action_attempted_at
    end
  end
end

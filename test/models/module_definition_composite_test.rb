# frozen_string_literal: true

require "test_helper"

class ModuleDefinitionCompositeTest < ActiveSupport::TestCase
  include CompositeHelper

  setup do
    build_composite_project
    build_pipeline
    @definition = stamp_composite(Modules::Composite::Extractor.new(workflow: @workflow, step_ids: [ @summarise.id, @approve.id, @send.id ],
                                                                    label: "Invoice flow").manifest.manifest)
    @user_session = nil
  end

  def kill_operation = @operation.update_columns(api_connector_id: create(:api_connector, scope: create(:project, company: @company, owner: @user), name: "other").id)

  test "a composite whose operation is gone can still be disabled, archived and rejected" do
    kill_operation

    assert @definition.update(enabled: false), @definition.errors.full_messages.to_sentence
    assert @definition.update(archived_at: Time.current), @definition.errors.full_messages.to_sentence
  end

  test "a waiting composite proposal whose operation is gone can still be rejected" do
    manifest = @definition.manifest.deep_dup.merge("slug" => "waiting")
    proposal = create(:module_definition, :proposed, scope: @project, kind: "block", namespace: "local", slug: "waiting", manifest: manifest)
    kill_operation

    assert proposal.update(rejected_at: Time.current, archived_at: Time.current), proposal.errors.full_messages.to_sentence
  end

  test "enabling it again or creating it with a dead reference is still refused" do
    @definition.update!(enabled: false)
    kill_operation

    assert_not @definition.update(enabled: true)
    assert_match(/REST operation/, @definition.errors[:manifest].join)
    fresh = build(:module_definition, scope: @project, kind: "block", namespace: "local", slug: "again", manifest: @definition.manifest.merge("slug" => "again"))
    assert_not fresh.valid?
  end
end

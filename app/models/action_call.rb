# frozen_string_literal: true

class ActionCall < ApplicationRecord
  OUTCOMES = %w[succeeded failed unknown].freeze

  belongs_to :step_run
  belongs_to :company
  belongs_to :project
  belongs_to :mcp_server, optional: true
  belongs_to :tool, optional: true
  belongs_to :api_operation, optional: true

  validates :target_type, inclusion: { in: Step::ACTION_TARGETS }
  validates :effect, inclusion: { in: Step::ACTION_EFFECTS }
  validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
  validates :attempted_at, presence: true

  before_validation :take_tenant_from_step_run, on: :create

  def self.digest(arguments)
    Digest::SHA256.hexdigest(JSON.generate(canonical(arguments)))
  end

  def self.canonical(value)
    case value
    when Hash then value.to_h { |k, v| [ k.to_s, canonical(v) ] }.sort.to_h
    when Array then value.map { |v| canonical(v) }
    else value
    end
  end
  private_class_method :canonical

  scope :resendable, -> { where.not(effect: "read").where(outcome: [ nil, "succeeded", "unknown" ]) }

  def server_name = transport.owner(transport.connection_of(self))

  def target_name = transport.target_name(transport.connection_of(self), stored_operation)

  def target_label = transport.label(transport.connection_of(self), stored_operation)

  def arguments=(arguments)
    self.arguments_digest = self.class.digest(arguments)
  end

  def finish!(outcome:, error: nil)
    now = Time.current
    update!(outcome: outcome, error: error, finished_at: now, duration_ms: ((now - attempted_at) * 1000).round)
  end

  private

  def transport = Connectors::Registry.for_target(target_type).new

  def stored_operation = Connectors::Operation.new(key: tool_name, name: tool_name, description: nil, input_schema: nil,
                                                   output_schema: nil, base_effect: nil, drifted: false)

  def take_tenant_from_step_run
    project = step_run&.workflow_run&.project
    return unless project

    self.project = project
    self.company_id = project.company_id
  end
end

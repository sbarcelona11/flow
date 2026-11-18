# frozen_string_literal: true

# ApiOperation — one call a connector offers: method, path template and the
# schema of the arguments it takes, grouped as `path`, `query` and `body`.
class ApiOperation < ApplicationRecord
  METHODS = %w[GET POST PUT PATCH DELETE].freeze
  NAME_FORMAT = /\A[a-z][a-z0-9_]{0,63}\z/
  PATH_MAX = 512
  PATH_FORMAT = %r{\A/(?:[A-Za-z0-9._~!$&'()*+,;=:@-]|%[0-9A-Fa-f]{2}|\{[A-Za-z_][A-Za-z0-9_]*\}|/)*\z}
  PLACEHOLDER = /\{([^{}]*)\}/
  ARGUMENT_GROUPS = %w[path query body].freeze

  belongs_to :api_connector

  validates :name, presence: true, format: { with: NAME_FORMAT, allow_blank: true }
  validates :name, uniqueness: { scope: :api_connector_id }
  validates :http_method, inclusion: { in: METHODS }
  validates :effect, inclusion: { in: Step::ACTION_EFFECTS }
  validate :effect_not_below_minimum
  validates :cost_cents, numericality: { only_integer: true, in: 0..Budgets::MAX_CENTS }, allow_nil: true
  validate :cost_cents_is_readable
  validate :path_template
  validate :input_schema_shape

  scope :enabled, -> { where(enabled: true) }

  # Clients sent `method` before the column became `http_method`; accepted until the next release.
  def self.with_legacy_method(attributes)
    legacy = attributes.delete("method")
    attributes["http_method"] ||= legacy if legacy
    attributes
  end

  def self.minimum_effect_for(http_method)
    http_method == "GET" ? "read" : "write"
  end

  def self.path_errors(value)
    value = value.to_s
    return [ "can't be blank" ] if value.blank?

    errors = []
    errors << "is too long (maximum #{PATH_MAX} characters)" if value.length > PATH_MAX
    return errors << "must be a path starting with / and using only URL-safe characters" unless value.match?(PATH_FORMAT)

    errors << "can't contain //" if value.include?("//")
    errors << "can't contain an encoded / or \\" if value.match?(/%(2f|5c)/i)
    errors << "can't contain . or .. segments" if value.split("/").any? { |segment| %w[. ..].include?(segment.gsub(/%2e/i, ".")) }
    errors
  end

  def minimum_effect
    self.class.minimum_effect_for(http_method)
  end

  def placeholders
    path.to_s.scan(PLACEHOLDER).flatten
  end

  private

  # Only nil means "not declared": a value the integer type cannot read must not be cast to nil, and
  # false must not be cast to a declared cost of 0.
  def cost_cents_is_readable
    raw = cost_cents_before_type_cast
    return unless raw == false || (cost_cents.nil? && !raw.nil?)

    errors.add(:cost_cents, "must be an integer")
  end

  def effect_not_below_minimum
    return unless METHODS.include?(http_method) && Step::ACTION_EFFECTS.include?(effect)
    return if Step::ACTION_EFFECTS.index(effect) >= Step::ACTION_EFFECTS.index(minimum_effect)

    errors.add(:effect, "can't be lower than #{minimum_effect} for a #{http_method} operation")
  end

  def path_template
    self.class.path_errors(path).each { |message| errors.add(:path, message) }
  end

  def input_schema_shape
    schema = input_schema
    return errors.add(:input_schema, "must be an object schema") unless schema.is_a?(Hash)

    SchemaHygiene.errors_for(schema).each { |message| errors.add(:input_schema, message) }
    return if errors[:input_schema].any?

    properties = schema["properties"]
    return errors.add(:input_schema, "properties must be an object") unless properties.nil? || properties.is_a?(Hash)

    (properties || {}).each do |group, group_schema|
      if ARGUMENT_GROUPS.exclude?(group)
        errors.add(:input_schema, "can only group arguments as path, query and body (found #{group})")
      elsif !group_schema.is_a?(Hash) || group_schema["type"] != "object"
        errors.add(:input_schema, "#{group} must be an object schema")
      end
    end
    path_placeholders_are_required
  end

  def path_placeholders_are_required
    path_schema = input_schema.dig("properties", "path")
    path_schema = {} unless path_schema.is_a?(Hash)
    declared = path_schema["properties"].is_a?(Hash) ? path_schema["properties"].keys : []
    required = Array(path_schema["required"])

    placeholders.uniq.each do |placeholder|
      next if declared.include?(placeholder) && required.include?(placeholder)

      errors.add(:path, "placeholder {#{placeholder}} must be a required path parameter in the input schema")
    end
  end
end

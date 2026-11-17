# frozen_string_literal: true

# Hygiene for a tenant-authored JSON Schema: meta-valid, no $ref family
# (client-breaking and a DoS surface), bounded size and depth. Shared by Tool
# and ApiOperation so both hold their input schemas to one standard.
module SchemaHygiene
  MAX_BYTES = 64_000
  MAX_DEPTH = 12
  FORBIDDEN_KEYS = %w[$ref $defs $dynamicRef $dynamicAnchor].freeze

  module_function

  def errors_for(schema)
    errors = []
    errors << "exceeds #{MAX_BYTES} bytes" if JSON.dump(schema).bytesize > MAX_BYTES
    errors << "nests deeper than #{MAX_DEPTH} levels" if depth(schema) > MAX_DEPTH
    bad_key = forbidden_key(schema)
    errors << "uses unsupported keyword #{bad_key}" if bad_key
    errors << "is not a valid JSON Schema" if errors.empty? && !JSONSchemer.valid_schema?(schema)
    errors
  end

  def depth(value, level = 1)
    case value
    when Hash then value.values.map { |v| depth(v, level + 1) }.max || level
    when Array then value.map { |v| depth(v, level + 1) }.max || level
    else level
    end
  end

  def forbidden_key(value)
    case value
    when Hash
      value.each do |k, v|
        return k if FORBIDDEN_KEYS.include?(k.to_s)

        found = forbidden_key(v)
        return found if found
      end
      nil
    when Array
      value.each { |v| (found = forbidden_key(v)) and return found }
      nil
    end
  end
end

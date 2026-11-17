# frozen_string_literal: true

module Modules
  # What a project can use: the built-in aixle types plus its own enabled module definitions. Resolution never raises
  # while listing; a module that cannot be used is reported with status "invalid" and the reason.
  class Registry
    class Unknown < StandardError; end

    BUILTIN_DIR = Rails.root.join("config/modules/aixle")
    BUILTIN_NAMESPACE = "aixle"
    MAX_TYPE_DEPTH = 8
    X_TYPE = "x-type"

    Entry = Data.define(:kind, :key, :manifest, :builtin, :status, :reason) do
      def label = manifest.label
      def executor = manifest.executor
      def ports = manifest.ports
      def config = manifest.config || {}
      def unresolved = status == "unresolved"
    end

    def self.builtin_types
      @builtin_types ||= Dir[BUILTIN_DIR.join("*.json")].map { |path| Manifest.parse(File.read(path)) }.freeze
    end

    def initialize(project, overlay: nil)
      @project = project
      @overlay = overlay
      @type_problems = {}
      @heights = {}
      @catalog = {}
    end

    def type(ref) = entry(:type, ref)
    def capability(ref) = entry(:capability, ref)
    def block(ref) = entry(:block, ref)

    def types = manifests_of("type").map { |manifest| entry_for(manifest) }

    def capabilities = manifests_of("capability").map { |manifest| entry_for(manifest) }

    def blocks = manifests_of("block").map { |manifest| entry_for(manifest) }

    def type_problem(key)
      return @type_problems[key] if @type_problems.key?(key)

      @type_problems[key] = compute_type_problem(key, [])
    end

    private

    def manifests
      @manifests ||= begin
        found = project_manifests.index_by { |manifest| [ manifest.kind, manifest.key ] }
        found.merge!(self.class.builtin_types.index_by { |manifest| [ manifest.kind, manifest.key ] })
        found[[ @overlay.kind, @overlay.key ]] = @overlay if @overlay
        found
      end
    end

    def project_manifests
      ModuleDefinition.for_project(@project).enabled.filter_map do |definition|
        manifest = Manifest.from_hash(definition.manifest)
        manifest unless manifest.namespace == BUILTIN_NAMESPACE
      rescue Manifest::Invalid
        nil
      end
    end

    def manifests_of(kind)
      manifests.each_value.select { |manifest| manifest.kind == kind }.sort_by(&:key)
    end

    def entry(kind, ref)
      ref = ref.to_s
      manifest = manifests[[ kind.to_s, ref ]]
      raise Unknown, unknown_message(kind, ref) unless manifest

      entry_for(manifest)
    end

    def unknown_message(kind, ref)
      return "Unknown #{kind} #{ref.inspect}: write it as namespace/slug@version." unless ref.match?(%r{\A[^@]+/[^@]+(@.*)?\z})
      return "Unknown #{kind} #{ref}: a version is required (for example #{ref}@1)." unless ref.include?("@")

      namespace, slug, = Manifest.split_ref(ref)
      base = "#{namespace}/#{slug}@"
      versions = manifests_of(kind.to_s).select { |manifest| "#{manifest.namespace}/#{manifest.slug}@" == base }.map(&:version)
      return "Unknown #{kind} #{ref}." if versions.empty?

      "Unknown #{kind} #{ref}: available versions are #{versions.sort.join(', ')}."
    end

    def entry_for(manifest)
      status, reason = assess(manifest)
      Entry.new(kind: manifest.kind, key: manifest.key, manifest: manifest, builtin: manifest.namespace == BUILTIN_NAMESPACE,
                status: status, reason: reason)
    end

    def assess(manifest)
      case manifest.kind
      when "type" then (problem = type_problem(manifest.key)) ? [ "invalid", problem ] : [ "valid", nil ]
      when "capability" then assess_capability(manifest)
      else assess_block(manifest)
      end
    end

    def assess_capability(manifest)
      problem = %w[input output].lazy.filter_map { |side| ref_problem(manifest.public_send(side), "#{side} type") }.first
      problem ? [ "invalid", problem ] : [ "valid", nil ]
    end

    def assess_block(manifest)
      problem = port_problem(manifest)
      return [ "invalid", problem ] if problem

      uses = manifest.uses
      return [ "valid", nil ] if uses.nil?

      if uses["capability"]
        missing = manifests.key?([ "capability", uses["capability"] ]) ? nil : unknown_message(:capability, uses["capability"])
        return missing ? [ "invalid", missing ] : [ "unresolved", "No connector provides capability #{uses['capability']} yet." ]
      end

      problem = action_problem(uses, manifest.effect)
      problem ? [ "invalid", problem ] : [ "valid", nil ]
    end

    def port_problem(manifest)
      ports = manifest.ports || {}
      %w[in out].each do |side|
        ports.fetch(side, {}).each do |name, ref|
          problem = ref_problem(ref, "port #{side}.#{name} type")
          return problem if problem
        end
      end
      nil
    end

    def ref_problem(ref, what)
      base = Manifest.unwrap_list(ref)
      return "#{what} #{ref.inspect} is not a valid reference." unless Manifest.split_ref(base)
      return "#{what} #{base} is unknown to this project: #{unknown_message(:type, base)}" unless manifests.key?([ "type", base ])

      problem = type_problem(base)
      problem && "#{what} #{base} is invalid: #{problem}"
    end

    def compute_type_problem(key, trail)
      return "reference cycle #{(trail + [ key ]).join(' -> ')}" if trail.include?(key)

      @type_problems[key] = resolve_type_problem(key, trail)
    end

    def resolve_type_problem(key, trail)
      manifest = manifests[[ "type", key ]]
      return unknown_message(:type, key) unless manifest

      height = 1
      type_references(manifest.schema).each do |ref|
        base = Manifest.unwrap_list(ref)
        return "#{X_TYPE} #{ref.inspect} is not a valid reference" unless Manifest.split_ref(base)
        return "#{X_TYPE} #{base} is unknown to this project: #{unknown_message(:type, base)}" unless manifests.key?([ "type", base ])

        child = @type_problems.fetch(base) { compute_type_problem(base, trail + [ key ]) }
        return child if child

        height = [ height, @heights.fetch(base, 1) + 1 ].max
      end
      return "nests type references deeper than #{MAX_TYPE_DEPTH} levels" if height > MAX_TYPE_DEPTH

      @heights[key] = height
      nil
    end

    def type_references(schema, found = [])
      case schema
      when Hash
        schema.each do |key, value|
          if key == X_TYPE && value.is_a?(String) then found << value
          else type_references(value, found)
          end
        end
      when Array then schema.each { |item| type_references(item, found) }
      end
      found.uniq
    end

    def action_problem(uses, effect)
      transport_key = uses["transport"]
      begin
        transport = Connectors::Registry.fetch(transport_key).new
      rescue Connectors::Registry::Unknown
        return "uses transport #{transport_key.inspect}, which is not registered."
      end

      operation = find_operation(transport, uses["connection"], uses["operation"])
      return "uses #{transport_key} operation #{uses['operation'].inspect} on connection #{uses['connection'].inspect}, which this project does not have." unless operation
      return if effect.nil? || Actions::Effect.at_least?(effect, operation.base_effect)

      "effect #{effect} is below the operation's own effect #{operation.base_effect}; a block can only raise it."
    end

    def find_operation(transport, connection_name, operation_name)
      @catalog[[ transport.class, connection_name ]] ||= begin
        candidates = transport.connections(@project).to_a.select { |connection| transport.owner(connection) == connection_name }
        candidates.flat_map { |connection| transport.operations(connection) }
      end
      @catalog[[ transport.class, connection_name ]].find { |op| op.key == operation_name || op.name == operation_name }
    end
  end
end

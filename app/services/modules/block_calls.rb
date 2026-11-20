# frozen_string_literal: true

module Modules
  # What a REST block would call right now, resolved the way the registry resolves it: its connector and operation by name in
  # the block's project. A reviewer reads this next to the manifest to see the real host and which secret goes there.
  class BlockCalls
    class << self
      def for(project:, definition:)
        uses = definition.manifest.is_a?(Hash) ? definition.manifest["uses"] : nil
        return unless definition.kind == "block" && uses.is_a?(Hash) && uses["transport"] == "rest"

        connector = ApiConnector.for_project(project).find_by(name: uses["connection"].to_s)
        operation = connector&.api_operations&.find_by(name: uses["operation"].to_s)
        return { "resolved" => false } unless operation

        { "resolved" => true, "connector" => connector.name, "operation" => operation.name, "method" => operation.http_method,
          "path" => operation.path, "host" => connector.host, "effect" => operation.effect, "connectorState" => connector.review_state,
          "secretBindings" => Rest::SecretBindings.for(auth_config: connector.auth_config, base_url: connector.base_url) }
      end
    end
  end
end

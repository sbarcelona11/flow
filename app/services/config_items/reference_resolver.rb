# frozen_string_literal: true

module ConfigItems
  class ReferenceResolver
    class Missing < StandardError
      attr_reader :name

      def initialize(name)
        @name = name
        super("config item #{name} does not exist in this project")
      end
    end

    def initialize(project:)
      @project = project
    end

    def resolve(text)
      used = {}
      resolved = text.to_s.gsub(MCPServer::CONFIG_ITEM_REFERENCE) do
        name = Regexp.last_match(1)
        item = used[name] ||= find(name)
        item.decrypted_value
      end
      [ resolved, used.values ]
    end

    private

    def find(name)
      ConfigItem.for_project(@project).find_by(name: name) || raise(Missing, name)
    end
  end
end

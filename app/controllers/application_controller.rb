# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include AuthConcern
  include FeatureGated

  helper_method :current_user, :true_user, :impersonated?

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern
  before_action :underscore_params

  def append_info_to_payload(payload)
    super
    payload[:host] = request.host
    payload[:ip] = request.env["HTTP_X_REAL_IP"]
    payload[:ff] = request.env["HTTP_X_FORWARDED_FOR"]
    # Only a user this request already resolved: resolving one here would touch or
    # forget the session of a request that never asked who was signed in.
    payload[:user] = @current_user&.id if defined?(@current_user_session)
  end

  # A bare `?q=foo` (or `q[]=`) is not a ransack query; ignore it rather than dig into it.
  def q_params
    q = params[:q]
    q.respond_to?(:permit) ? q : {}
  end

  # Param paths whose hash values should not have keys underscored.
  # Override in subcontrollers: [[:mcpServer, :env], [:mcpServer, :headers]]
  def preserved_param_paths
    []
  end

  def underscore_params
    raw = preserved_param_paths.each_with_object({}) do |path, memo|
      value = params.dig(*path)
      memo[path] = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    end

    raw.merge!(action_argument_paths(params.to_unsafe_h))

    params.deep_transform_keys! { |key| key.to_s.underscore }

    raw.each do |path, value|
      underscored = path.map { |s| s.is_a?(Integer) ? s : s.to_s.underscore }
      target = params
      underscored[0..-2].each { |seg| target = target[seg] }
      target[underscored.last] = value
    end
  end

  # An action step's tool arguments are named by the tool, not by us: the subtree
  # under `kind_config.arguments` keeps its keys verbatim wherever the step sits in the payload.
  def action_argument_paths(node, path = [], found = {})
    case node
    when Hash
      node.each do |key, value|
        if %w[kind_config kindConfig].include?(key.to_s) && value.is_a?(Hash) && value["arguments"].is_a?(Hash)
          found[path + [ key, "arguments" ]] = value["arguments"].to_h
        end
        action_argument_paths(value, path + [ key ], found)
      end
    when Array
      node.each_with_index { |item, index| action_argument_paths(item, path + [ index ], found) }
    end
    found
  end

  private

  # Versions are attributed to the person at the keyboard: an admin
  # impersonating a user edits as themselves in the history.
  def version_actor
    Versions::Actor.ui(true_user || current_user)
  end
end

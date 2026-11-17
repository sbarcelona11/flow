# frozen_string_literal: true

# ApiConnector — a REST API a project's action steps can call. Project-scoped.
#
# Secrets are never stored here: `auth_config` names the Config Items that hold
# them, resolved at call time.
class ApiConnector < ApplicationRecord
  AUTH_TYPES = %w[none bearer api_key_header api_key_query basic].freeze
  ITEM_NAME = /\A[A-Z][A-Z0-9_]*\z/
  HEADER_NAME = /\A[A-Za-z0-9-]+\z/
  QUERY_PARAM = /\A[A-Za-z0-9_.-]+\z/
  CREDENTIAL_HEADER = /\A(authorization|proxy-authorization|cookie|set-cookie)\z|(key|token|secret)\z/i

  belongs_to :scope, polymorphic: true
  include TenantColumns
  include Archivable

  before_validation :strip_trailing_slash

  has_many :api_operations, dependent: :destroy

  validates :name, presence: true
  validates :name, uniqueness: { scope: %i[scope_type scope_id], conditions: -> { where(archived_at: nil) },
                                 message: "already exists in this project" }
  validates :scope_type, inclusion: { in: %w[Project], message: "must be a project" }
  validates :auth_type, inclusion: { in: AUTH_TYPES }
  validate :base_url_shape, if: :will_save_change_to_base_url?
  validate :base_url_safety, if: :will_save_change_to_base_url?
  validate :auth_config_shape
  validate :default_headers_are_not_credentials

  scope :for_project, ->(project) { unarchived.where(scope_type: "Project", scope_id: project.id) }
  scope :enabled, -> { where(enabled: true) }

  def host
    URI.parse(base_url.to_s).host.to_s
  rescue URI::InvalidURIError
    ""
  end

  def self.ransackable_attributes(_auth_object = nil)
    %w[name auth_type enabled created_at updated_at]
  end

  def self.ransackable_associations(_auth_object = nil)
    []
  end

  private

  def strip_trailing_slash
    self.base_url = base_url.sub(%r{/+\z}, "") if base_url.is_a?(String)
  end

  def base_url_shape
    uri = UrlSafetyValidator.safe_parse(base_url)
    return if uri.nil? || base_url.blank?

    errors.add(:base_url, "must have a host") if uri.host.blank?
    errors.add(:base_url, "can't carry credentials") if uri.userinfo.present?
    errors.add(:base_url, "can't carry a query or fragment") if uri.query || uri.fragment || base_url.match?(/[?#]/)
  end

  def base_url_safety
    UrlSafetyValidator.errors_for(base_url, require_https: true).each { |message| errors.add(:base_url, message) }
  end

  def auth_config_shape
    config = auth_config
    return errors.add(:auth_config, "must be an object") unless config.is_a?(Hash)

    case auth_type
    when "bearer"
      require_item(config, "config_item_name")
    when "api_key_header"
      require_item(config, "config_item_name")
      require_format(config, "header_name", HEADER_NAME)
    when "api_key_query"
      require_item(config, "config_item_name")
      require_format(config, "query_param", QUERY_PARAM)
    when "basic"
      require_item(config, "username_item")
      require_item(config, "password_item")
    end
  end

  def require_item(config, key)
    require_format(config, key, ITEM_NAME, "must name a Config Item (uppercase letters, digits, underscores)")
  end

  def require_format(config, key, format, message = "is invalid")
    value = config[key]
    if value.blank?
      errors.add(:auth_config, "#{key} is required for #{auth_type} auth")
    elsif !value.is_a?(String) || !value.match?(format)
      errors.add(:auth_config, "#{key} #{message}")
    end
  end

  def default_headers_are_not_credentials
    return errors.add(:default_headers, "must be an object") unless default_headers.is_a?(Hash)

    default_headers.each do |header, value|
      if !header.to_s.match?(HEADER_NAME)
        errors.add(:default_headers, "#{header} is not a valid header name")
      elsif header.to_s.match?(CREDENTIAL_HEADER)
        errors.add(:default_headers, "#{header} looks like a credential; use the connector's authentication instead")
      elsif !value.is_a?(String) || value.match?(/[\r\n]/)
        errors.add(:default_headers, "#{header} must be a single-line text value")
      end
    end
  end
end

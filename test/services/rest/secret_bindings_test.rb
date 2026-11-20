# frozen_string_literal: true

require "test_helper"

module Rest
  class SecretBindingsTest < ActiveSupport::TestCase
    test "names each Config Item next to the host it is sent to" do
      assert_equal [ "STRIPE_KEY → api.example.com" ],
                   SecretBindings.for(auth_config: { "config_item_name" => "STRIPE_KEY" }, base_url: "https://API.example.com./v1")
    end

    test "lists the user and password items of basic auth once each" do
      bindings = SecretBindings.for(auth_config: { "username_item" => "U", "password_item" => "P" }, base_url: "https://h.example.com")

      assert_equal [ "U → h.example.com", "P → h.example.com" ], bindings
    end

    test "has nothing to say without a secret or a readable host" do
      assert_empty SecretBindings.for(auth_config: {}, base_url: "https://h.example.com")
      assert_empty SecretBindings.for(auth_config: { "config_item_name" => "K" }, base_url: "not a url")
      assert_empty SecretBindings.for(auth_config: nil, base_url: nil)
    end
  end
end

# src/mcp/subscriptions.cr
require "json"

module MCP
  struct SubscriptionFilter
    include JSON::Serializable

    @[JSON::Field(key: "toolsListChanged", emit_null: false)]
    getter tools_list_changed : Bool?

    @[JSON::Field(key: "promptsListChanged", emit_null: false)]
    getter prompts_list_changed : Bool?

    @[JSON::Field(key: "resourcesListChanged", emit_null: false)]
    getter resources_list_changed : Bool?

    @[JSON::Field(key: "resourceSubscriptions", emit_null: false)]
    getter resource_subscriptions : Array(String)?

    def initialize(@tools_list_changed : Bool? = nil, @prompts_list_changed : Bool? = nil,
                   @resources_list_changed : Bool? = nil, @resource_subscriptions : Array(String)? = nil)
    end

    def self.all : self
      new(tools_list_changed: true, prompts_list_changed: true, resources_list_changed: true)
    end
  end

  struct SubscriptionsListenParams
    include JSON::Serializable

    getter notifications : SubscriptionFilter

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : RequestMeta?

    def initialize(@notifications : SubscriptionFilter, @meta : RequestMeta? = nil)
    end
  end

  struct SubscriptionsListenResult
    include JSON::Serializable

    @[JSON::Field(key: "resultType")]
    getter result_type : String = RESULT_TYPE_COMPLETE

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : ResultMeta?

    def initialize(@result_type : String = RESULT_TYPE_COMPLETE, @meta : ResultMeta? = nil)
    end
  end

  struct SubscriptionsAcknowledgedParams
    include JSON::Serializable

    getter notifications : SubscriptionFilter

    @[JSON::Field(key: "_meta", emit_null: false)]
    getter meta : NotificationMeta?

    def initialize(@notifications : SubscriptionFilter, @meta : NotificationMeta? = nil)
    end
  end
end

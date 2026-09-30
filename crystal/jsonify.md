# The JSONify Pattern in Crystal

When building applications in Crystal, the standard way to convert objects to JSON is by including the `JSON::Serializable` module in your structs or classes. However, when interfacing with highly complex, deeply nested, or dynamic third-party APIs (like YouTube's internal API or Large Language Model APIs), defining 1-to-1 data structs can become overwhelming and rigid. 

To solve this, developers can adopt the **JSONify Pattern**—a technique popularized by projects like the Invidious YouTube frontend.

## What is the JSONify Pattern?

The JSONify pattern relies on Crystal's built-in `JSON::Builder` to manually construct JSON structures on the fly. 

Instead of instantiating an object and calling `.to_json`, you create a dedicated namespace (e.g., `MyProject::JSONify`) containing stateless methods. These methods accept a `JSON::Builder` instance and stream fields, arrays, and objects directly to the output.

## Why Not `JSON::Serializable`?

While `JSON::Serializable` is excellent for standard data models, it struggles when:
1. **The JSON shape is highly dynamic:** For example, an LLM message array where elements might be plain text, image blocks, or tool call results, each requiring entirely different key-value pairs.
2. **You only need to generate JSON, not parse it:** If you are strictly outputting data to an external service, creating dozens of intermediate structs just to call `.to_json` wastes memory.
3. **The payload is deeply nested:** Structuring 5 levels of nested objects requires 5 separate Crystal structs, which clutters your codebase.

## How It Works

The core of the pattern is passing a `JSON::Builder` object down a chain of helper methods.

### 1. Define the Builder Methods
Create a module to encapsulate your JSON generation logic:

```crystal
require "json"

module API::JSONify
  def self.user(json : JSON::Builder, username : String, role : String)
    json.object do
      json.field "username", username
      json.field "role", role
      json.field "metadata" do
        # You can delegate deeply nested parts to other methods
        metadata(json)
      end
    end
  end

  def self.metadata(json : JSON::Builder)
    json.object do
      json.field "created_at", Time.utc.to_s
      json.field "active", true
    end
  end
end
```

### 2. Stream the JSON
When it's time to generate the payload, open a `JSON.build` block and pass the builder into your `JSONify` methods. You can write this directly to an HTTP request or a String:

```crystal
require "http/client"

# Generate directly to a string
payload = JSON.build do |json|
  API::JSONify.user(json, "crystal_dev", "admin")
end

# Or stream directly to an IO (like an HTTP client body)
HTTP::Client.post("https://api.example.com", body: payload)
```

## Practical Example: LLM APIs

Large Language Model APIs (like Moonshot/Kimi, OpenAI, or Anthropic) are the perfect use case for this pattern. Their chat completion endpoints often require nested parameters for reasoning effort, dynamic multi-modal message arrays, and complex JSON schemas for tool definitions.

Using the JSONify pattern, you can isolate this API contract:

```crystal
module LLM::JSONify
  def self.chat_request(json : JSON::Builder, prompt : String, model = "kimi-k3")
    json.object do
      json.field "model", model
      
      json.field "messages" do
        json.array do
          json.object do
            json.field "role", "user"
            json.field "content", prompt
          end
        end
      end

      # Easily handle optional or complex nested fields
      json.field "response_format" do
        json.object do
          json.field "type", "json_object"
        end
      end
    end
  end
end
```

## Key Benefits

*   **Zero Intermediate Allocations:** You don't have to create Crystal structs/objects just to immediately throw them away after serialization. The JSON is streamed directly to memory or IO.
*   **Decoupling:** It separates your internal domain models from the exact JSON shape required by the external API.
*   **Flexibility:** It's trivial to conditionally add fields (e.g., `json.field("max_tokens", 100) if user_is_premium`) without wrestling with `nil` checks in struct initializers.
*   **Clean Routing:** Keeps HTTP handler or routing files clean by pushing all the messy JSON construction into a dedicated namespace.
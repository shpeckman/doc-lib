---
name: crystal-mcp-builder
description: Guide for creating high-quality MCP (Model Context Protocol) servers in Crystal using the crystal-mcp shard (protocol version 2026-07-28, https://github.com/shpeckman/crystal-mcp). Use when the user wants to build an MCP server or MCP tools in Crystal, expose an external API, service, or database to LLMs through MCP from a Crystal codebase, or asks about the crystal-mcp shard, Crystal MCP development, Crystal stdio/Streamable HTTP MCP transports, or creating evaluations for an MCP server.
---

# Crystal MCP Server Development Guide

## Overview

Create MCP (Model Context Protocol) servers in Crystal that enable LLMs to interact with external services through well-designed tools. The quality of an MCP server is measured by how well it enables LLMs to accomplish real-world tasks.

All servers built with this skill use the **crystal-mcp shard** (https://github.com/shpeckman/crystal-mcp), a complete implementation of MCP protocol version **2026-07-28** for Crystal >= 1.21: typed protocol surface, JSON-RPC sessions, stdio and Streamable HTTP transports, an ergonomic server DSL, and a full client for testing.

---

# Process

## 🚀 High-Level Workflow

Creating a high-quality MCP server involves four main phases:

### Phase 1: Deep Research and Planning

#### 1.1 Understand Modern MCP Design

**API Coverage vs. Workflow Tools:**
Balance comprehensive API endpoint coverage with specialized workflow tools. Workflow tools can be more convenient for specific tasks, while comprehensive coverage gives agents flexibility to compose operations. Performance varies by client—some clients benefit from code execution that combines basic tools, while others work better with higher-level workflows. When uncertain, prioritize comprehensive API coverage.

**Tool Naming and Discoverability:**
Clear, descriptive tool names help agents find the right tools quickly. Use consistent prefixes (e.g., `github_create_issue`, `github_list_repos`) and action-oriented naming.

**Context Management:**
Agents benefit from concise tool descriptions and the ability to filter/paginate results. Design tools that return focused, relevant data.

**Actionable Error Messages:**
Error messages should guide agents toward solutions with specific suggestions and next steps.

#### 1.2 Study MCP Protocol Documentation

The crystal-mcp shard implements the **2026-07-28** protocol revision. Notable differences from older revisions: the handshake is `server/discover` (not `initialize`), subscriptions use `subscriptions/listen` streams with filters, results carry a `resultType` (`complete` / `input_required`), and sampling supports tool use. You rarely need to touch these directly — the shard handles them — but read the spec when behavior surprises you:

Start with the sitemap to find relevant pages: `https://modelcontextprotocol.io/sitemap.xml`

Then fetch specific pages with `.md` suffix for markdown format (e.g., `https://modelcontextprotocol.io/specification/2026-07-28.md`).

Key pages to review:
- Specification overview and architecture
- Transport mechanisms (Streamable HTTP, stdio)
- Tool, resource, and prompt definitions

#### 1.3 Load Framework Documentation

**Recommended stack:**
- **Language**: Crystal >= 1.21 with the bundled crystal-mcp shard
- **Transport**: stdio for local servers; Streamable HTTP (`server.run_http`) for remote servers

**Load in this order:**

- **MCP Best Practices**: [📋 View Best Practices](./references/mcp_best_practices.md) - Core guidelines (load first)
- **Crystal Implementation Guide**: [🔮 Crystal Guide](./references/crystal_mcp_server.md) - Complete crystal-mcp patterns and examples (load during Phase 2)
- The shard's own README (https://github.com/shpeckman/crystal-mcp/blob/main/README.md) is a full API reference — consult it for exact type signatures when the Crystal Guide is not enough.

#### 1.4 Plan Your Implementation

**Understand the API:**
Review the service's API documentation to identify key endpoints, authentication requirements, and data models. Use web search as needed.

**Tool Selection:**
Prioritize comprehensive API coverage. List endpoints to implement, starting with the most common operations.

---

### Phase 2: Implementation

#### 2.1 Set Up Project Structure

Detailed instructions live in the Crystal Guide; the short version:

1. **Crystal toolchain**: verify `crystal --version` is >= 1.21. If Crystal is missing, see "Environment Setup" in [🔮 Crystal Guide](./references/crystal_mcp_server.md). If the `dev` skill is available in this session, prefer its `install_crystal.py` installer and `crystal_preflight.py` linter.
2. **Scaffold the project**: create the `src/app.cr` / `src/server.cr` / `spec/` layout shown in the Crystal Guide; the repo's `examples/` directory has working servers to crib from.
3. **Add the shard**: declare `mcp: github: shpeckman/crystal-mcp` as a dependency in `shard.yml`, then run `shards install`. If GitHub is unreachable from the build host, `git clone https://github.com/shpeckman/crystal-mcp vendor/mcp` and use a `path: vendor/mcp` dependency instead.
4. **Name** the shard `{service}-mcp` — both `name:` in `shard.yml` and the `MCP::Implementation` name.

#### 2.2 Implement Core Infrastructure

Create shared utilities:
- API client with authentication (wrap `HTTP::Client`; see "Shared Utilities" in the Crystal Guide)
- Error handling helpers
- Response formatting (JSON/Markdown)
- Pagination support

#### 2.3 Implement Tools

For each tool:

**Input Schema:**
- Pass a NamedTuple literal as `input_schema:` — it becomes the JSON Schema object verbatim
- Include constraints (`minimum`, `enum`, `pattern`) and clear per-field `description`s
- Add examples in field descriptions

**Output Schema:**
- Define `output_schema:` where possible for structured data
- Return `structured_content` alongside text via `MCP::CallToolResult.new(content:, structured_content:)`

**Tool Description:**
- Concise summary of functionality
- Parameter semantics and return shape

**Implementation:**
- Handlers receive `args : Hash(String, JSON::Any)` — extract with `args["x"].as_s` / `as_i64` / `as_f` / `as_bool`, and `args["x"]?.try(&.as_s)` for optional fields
- Proper error handling with actionable messages (`MCP::CallToolResult.error`)
- Support pagination where applicable

**Annotations:**
- `read_only_hint`, `destructive_hint`, `idempotent_hint`, `open_world_hint` via `MCP::ToolAnnotations.new(...)`

---

### Phase 3: Review and Test

#### 3.1 Code Quality

Review for:
- No duplicated code (DRY principle)
- Consistent error handling
- Clear tool descriptions

#### 3.2 Build and Test

- Build: `mkdir -p bin && crystal build src/server.cr -o bin/server` (add `--release` for production)
- Run specs: `crystal spec` (write in-process `IO.pipe` integration specs — pattern in the Crystal Guide)
- If the `dev` skill is present, run its preflight linter on every `.cr` file: `python3 <dev-skill>/scripts/crystal_preflight.py FILE.cr...` (without `--fix` on files containing the word "while" in string literals)
- Test with MCP Inspector: `npx @modelcontextprotocol/inspector ./bin/server`
- Work through the full quality checklist in the Crystal Guide before considering the server done

---

### Phase 4: Create Evaluations

After implementing your MCP server, create comprehensive evaluations to test its effectiveness.

**Load [✅ Evaluation Guide](./references/evaluation.md) for complete evaluation guidelines.**

#### 4.1 Understand Evaluation Purpose

Use evaluations to test whether LLMs can effectively use your MCP server to answer realistic, complex questions.

#### 4.2 Create 10 Evaluation Questions

1. **Tool Inspection**: List available tools and understand their capabilities
2. **Content Exploration**: Use READ-ONLY operations to explore available data
3. **Question Generation**: Create 10 complex, realistic questions
4. **Answer Verification**: Solve each question yourself to verify answers

#### 4.3 Evaluation Requirements

Ensure each question is:
- **Independent**: Not dependent on other questions
- **Read-only**: Only non-destructive operations required
- **Complex**: Requiring multiple tool calls and deep exploration
- **Realistic**: Based on real use cases humans would care about
- **Verifiable**: Single, clear answer that can be verified by string comparison
- **Stable**: Answer won't change over time

#### 4.4 Output Format

Create an XML file with this structure:

```xml
<evaluation>
  <qa_pair>
    <question>Find discussions about AI model launches with animal codenames. One model needed a specific safety designation that uses the format ASL-X. What number X was being determined for the model named after a spotted wild cat?</question>
    <answer>3</answer>
  </qa_pair>
<!-- More qa_pairs... -->
</evaluation>
```

#### 4.5 Run the Evaluation

Use the bundled harness (`scripts/evaluation.py`, works against any MCP server — stdio or HTTP — regardless of implementation language):

```bash
pip install anthropic mcp
export ANTHROPIC_API_KEY=your_api_key_here

# Crystal stdio server (compiled binary)
python3 scripts/evaluation.py -t stdio -c ./bin/server evaluation.xml

# Crystal server over Streamable HTTP
python3 scripts/evaluation.py -t http -u http://127.0.0.1:3000/mcp evaluation.xml
```

---

# Reference Files

## 📚 Documentation Library

Load these resources as needed during development:

### Core MCP Documentation (Load First)
- **MCP Protocol**: Start with sitemap at `https://modelcontextprotocol.io/sitemap.xml`, then fetch specific pages with `.md` suffix
- [📋 MCP Best Practices](./references/mcp_best_practices.md) - Universal MCP guidelines:
  - Server and tool naming conventions
  - Response format guidelines (JSON vs Markdown)
  - Pagination best practices
  - Transport selection (Streamable HTTP vs stdio)
  - Security and error handling standards

### Crystal Implementation Guide (Load During Phase 1/2)
- [🔮 Crystal Implementation Guide](./references/crystal_mcp_server.md) - Complete crystal-mcp guide:
  - Environment setup and project structure
  - Server initialization and tool registration DSL
  - Input schemas, output schemas, structured content
  - Resources, templates, prompts, completion
  - Subscriptions, notifications, sampling, elicitation, roots
  - stdio + Streamable HTTP transports
  - Error handling, testing patterns, Crystal pitfalls, quality checklist
- The shard's README (https://github.com/shpeckman/crystal-mcp/blob/main/README.md) - Full API reference for the shard

### Evaluation Guide (Load During Phase 4)
- [✅ Evaluation Guide](./references/evaluation.md) - Complete evaluation creation guide:
  - Question creation guidelines
  - Answer verification strategies
  - XML format specifications
  - Example questions and answers
  - Running the bundled evaluation harness

## 📦 Bundled Resources

- The crystal-mcp shard lives at https://github.com/shpeckman/crystal-mcp (source, full API README, runnable `examples/`). Add it as a shard dependency; clone the repo when you need to read exact type signatures locally.
- `scripts/evaluation.py`, `scripts/connections.py` - Language-agnostic MCP evaluation harness (Python; needs `anthropic` + `mcp` packages).

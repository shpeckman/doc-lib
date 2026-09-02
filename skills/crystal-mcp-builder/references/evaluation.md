# MCP Server Evaluation Guide

## Overview

Evaluations test whether LLMs can effectively use your MCP server to answer realistic, complex questions. This guide covers creating high-quality evaluation questions and running them with the bundled harness (`scripts/evaluation.py`), which works against any MCP server regardless of implementation language.

## Quick Reference

### Evaluation Requirements

- **Independent**: Each question stands alone
- **Read-only**: Only non-destructive operations
- **Complex**: Multiple tool calls required
- **Realistic**: Real human use cases
- **Verifiable**: Single, clear answer
- **Stable**: Answer won't change over time

### Output Format

```xml
<evaluation>
  <qa_pair>
    <question>...</question>
    <answer>...</answer>
  </qa_pair>
</evaluation>
```

---

## Purpose of Evaluations

Evaluations are a testbed for MCP servers to ensure agents can use the servers effectively. They measure whether a server helps users achieve goals by executing tasks with the tools provided. An agent + MCP server should be able to answer evaluation questions correctly, requiring tool calls to find answers.

## Evaluation Overview

Create 10 realistic, complex, verifiable questions with answers derived from actually using the MCP server tools.

## Question Guidelines

### Core Requirements

1. **Questions must be INDEPENDENT**
   - Each question is answered in a new conversation window
   - Prior answers are NOT available to subsequent questions
   - Do not design questions that build on each other

2. **Questions must be READ-ONLY**
   - Do not require WRITE or DESTRUCTIVE operations
   - All operations must be IDEMPOTENT and NON-DESTRUCTIVE
   - Assume destructive operations will be rejected by a human-in-the-loop

3. **Questions must be VERIFIABLE with single, clear answers**
   - Unambiguous, deterministic answers that can be derived from the tools
   - No special formatting or complex structured outputs
   - Verified using DIRECT STRING COMPARISON

4. **Questions must be SELF-CONTAINED**
   - Include all context, motivation, and required parameters in the question itself

### Complexity and Depth

5. **Questions must require MULTIPLE TOOL CALLS and DEEP EXPLORATION**
   - NOT solvable with a single tool call or simple search
   - May require multi-hop reasoning, gathering information from multiple sources, or aggregating multiple data sources
   - Avoid simple keyword searches with exact matches

6. **Answers must NOT be directly reachable via simple search**
   - Require exploration and tool usage
   - When a question mentions an entity (e.g., a project), do not include its proper name

7. **Questions should reflect REALISTIC SCENARIOS**
   - Realistic information retrieval tasks
   - Complex aggregation, filtering, and analysis
   - Comparison questions

### Tool Testing

8. **Questions should stress-test tool return values**
   - May elicit tools returning large JSON objects or lists
   - Should require understanding multiple modalities of data: IDs and names, timestamps and datetimes, URLs, file metadata
   - Probe the tool's ability to return all useful forms of data

9. **Questions should MOSTLY reflect real human use cases**

10. **Questions may require dozens of tool calls**
    - Challenges LLMs with limited context
    - Encourages MCP server tools to reduce information returned

11. **Include ambiguous questions**
    - May force difficult decisions about which tools to call
    - Despite ambiguity, there must STILL be a single verifiable answer

### Stability

12. **Questions must be designed so the answer DOES NOT CHANGE**
    - Do not rely on dynamic "current state" (reaction counts, reply counts, member counts)

13. **DO NOT let the MCP server RESTRICT the kinds of questions you create**
    - Create challenging questions; some may not be solvable with the available tools
    - Questions may require specific output formats or dozens of tool calls

## Answer Guidelines

### Verification

1. **Answers must be VERIFIABLE via direct string comparison**
   - If the answer can be written in many formats, specify the format in the QUESTION ("Use YYYY/MM/DD.", "Respond True or False.", "Answer A, B, C, or D and nothing else.")
   - Good answer types: names, IDs, URLs, titles, numerical quantities, timestamps, booleans, email addresses, file names, multiple choice letters
   - No complex structured output required

### Readability

2. **Answers should generally prefer HUMAN-READABLE formats**
   - Names, datetimes, file names, URLs, yes/no, a/b/c/d
   - Rather than opaque IDs (though IDs are acceptable)

### Stability

3. **Answers must be STABLE/STATIONARY**
   - Base questions on "closed" concepts: ended conversations, launched projects, answered questions
   - Use fixed time windows to insulate from non-stationary answers
   - Be specific enough that later events cannot change the answer

4. **Answers must be CLEAR and UNAMBIGUOUS**
   - A single clear answer derivable from the MCP server tools

### Diversity

5. **Answers must be DIVERSE** across modalities and formats

6. **Answers must NOT be complex structures**
   - Not lists of values, not complex objects, not natural language paragraphs
   - Unless straightforwardly verifiable by direct string comparison

## Evaluation Process

### Step 1: Documentation Inspection

Read the documentation of the target API: available endpoints, functionality, data models. Fetch additional information from the web if ambiguous. Parallelize as much as possible.

### Step 2: Tool Inspection

List the tools available in the MCP server (e.g. with `MCP::Client#list_all_tools`, the MCP Inspector, or by reading `tools/list` output):
- Understand input/output schemas and descriptions
- WITHOUT calling the tools at this stage

### Step 3: Developing Understanding

Repeat steps 1 & 2 until you have a good understanding. At NO stage should you READ the code of the MCP server implementation itself — evaluate the server as a black box, the way an agent experiences it.

### Step 4: Read-Only Content Inspection

Use the MCP server tools to inspect content:
- READ-ONLY, NON-DESTRUCTIVE, IDEMPOTENT operations ONLY
- Goal: identify specific content (users, issues, documents) for realistic questions
- BE CAREFUL: some tools return LOTS OF DATA — make incremental, small, targeted calls, use `limit` (<10) and pagination
- Parallelize with sub-agents where available

### Step 5: Task Generation

Create 10 questions following all guidelines above.

## Output Format

```xml
<evaluation>
   <qa_pair>
      <question>Find the project created in Q2 2024 with the highest number of completed tasks. What is the project name?</question>
      <answer>Website Redesign</answer>
   </qa_pair>
   <qa_pair>
      <question>Search for issues labeled as "bug" that were closed in March 2024. Which user closed the most issues? Provide their username.</question>
      <answer>sarah_dev</answer>
   </qa_pair>
   <qa_pair>
      <question>Look for pull requests that modified files in the /api directory and were merged between January 1 and January 31, 2024. How many different contributors worked on these PRs?</question>
      <answer>7</answer>
   </qa_pair>
</evaluation>
```

## Evaluation Examples

### Good Questions

**Example 1: Multi-hop question requiring deep exploration (GitHub MCP)**

```xml
<qa_pair>
   <question>Find the repository that was archived in Q3 2023 and had previously been the most forked project in the organization. What was the primary programming language used in that repository?</question>
   <answer>Python</answer>
</qa_pair>
```

- Requires multiple searches to find archived repositories
- Needs to identify which had the most forks before archival
- Requires examining repository details for the language
- Answer is simple, verifiable, and based on historical data that won't change

**Example 2: Complex aggregation (Issue Tracker MCP)**

```xml
<qa_pair>
   <question>Among all bugs reported in January 2024 that were marked as critical priority, which assignee resolved the highest percentage of their assigned bugs within 48 hours? Provide the assignee's username.</question>
   <answer>alex_eng</answer>
</qa_pair>
```

- Requires filtering by date, priority, and status
- Needs grouping and rate calculations from timestamps
- Tests pagination over many results
- Single, stable, human-readable answer

### Poor Questions

**Example 1: Answer changes over time**

```xml
<qa_pair>
   <question>How many open issues are currently assigned to the engineering team?</question>
   <answer>47</answer>
</qa_pair>
```

The answer changes as issues are created, closed, or reassigned.

**Example 2: Too easy with keyword search**

```xml
<qa_pair>
   <question>Find the pull request with title "Add authentication feature" and tell me who created it.</question>
   <answer>developer123</answer>
</qa_pair>
```

Solvable with a single exact-match search; no exploration or synthesis needed.

**Example 3: Ambiguous answer format**

```xml
<qa_pair>
   <question>List all the repositories that have Python as their primary language.</question>
   <answer>repo1, repo2, repo3, data-pipeline, ml-tools</answer>
</qa_pair>
```

A list that could be returned in any order or format — ask for a count or superlative instead.

## Verification Process

After creating evaluations:

1. **Examine the XML file** to understand the schema
2. **Solve each task yourself** using the MCP server and tools (in parallel where possible)
3. **Flag any operations** that require WRITE or DESTRUCTIVE operations
4. **Replace incorrect answers** with the verified correct ones
5. **Remove any `<qa_pair>`** that requires WRITE or DESTRUCTIVE operations

## Tips for Creating Quality Evaluations

1. **Think hard and plan ahead** before generating tasks
2. **Parallelize** where possible to manage context
3. **Focus on realistic use cases** humans would actually want
4. **Create challenging questions** that test the server's limits
5. **Ensure stability** with historical data and closed concepts
6. **Verify answers** by solving the questions yourself
7. **Iterate and refine** based on what you learn

---

# Running Evaluations

Use the bundled harness (`scripts/evaluation.py` + `scripts/connections.py`). It connects to the MCP server as a client, lists its tools, and runs each question through an agent loop with Claude, scoring answers by exact string comparison and producing a Markdown report with per-task summaries and tool feedback.

The harness handshakes with `server/discover` first (2026-07-28 servers, including all crystal-mcp servers) and falls back to legacy `initialize` — it works against both modern and older MCP servers. Requires the `mcp` Python SDK (2.x) and `anthropic`.

## Setup

```bash
pip install anthropic mcp
export ANTHROPIC_API_KEY=your_api_key_here
```

## Evaluation File Format

XML with `<qa_pair>` elements as shown above.

## Running Against a Crystal Server

```bash
# stdio (compiled binary)
crystal build src/server.cr -o bin/server --release
python3 scripts/evaluation.py -t stdio -c ./bin/server evaluation.xml

# stdio with environment variables
python3 scripts/evaluation.py -t stdio -c ./bin/server -e MYSERVICE_API_KEY=sk-... evaluation.xml

# Streamable HTTP (server started with PORT=3000 ./bin/server)
python3 scripts/evaluation.py -t http -u http://127.0.0.1:3000/mcp evaluation.xml

# HTTP with headers and custom model
python3 scripts/evaluation.py -t http -u https://example.com/mcp \
  -H "Authorization: Bearer token" -m claude-sonnet-4-5 evaluation.xml

# Save the report
python3 scripts/evaluation.py -t stdio -c ./bin/server evaluation.xml -o report.md
```

## Interpreting Results

The report shows accuracy (exact string match), per-task tool calls with durations, the agent's `<summary>` of its approach, and its `<feedback>` on the tools. Use failures and feedback to improve tool descriptions, schemas, error messages, and response sizes — that is the primary value of the evaluation loop.

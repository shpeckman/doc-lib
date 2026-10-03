---
name: intent-layer
description: Hierarchical AGENTS.md infrastructure for codebases. Creates, audits, and maintains a root AGENTS.md plus child AGENTS.md intent nodes in complex subdirectories so coding agents navigate the repo with local purpose, contracts, patterns, and anti-patterns. Use when the user asks to set up, improve, or audit AGENTS.md files, add agent context or onboarding documentation to a codebase, build an intent layer, decide which directories deserve their own AGENTS.md, measure directory token sizes to place context files, or interview domain experts to capture codebase knowledge.
---

# Intent Layer

Hierarchical `AGENTS.md` infrastructure so agents navigate codebases with local context.

## Core Principle

**Exactly one root context file: `AGENTS.md` at the project root.** Never create a second root-level context file. Child `AGENTS.md` files in subdirectories are encouraged for complex subsystems.

## Workflow

1. **Detect state** — run `bash scripts/detect_state.sh <project-path>`. Returns `none`, `partial`, or `complete`.
2. **Route** by state:
   - `none` or `partial` → initial setup (steps 3-5)
   - `complete` → maintenance (step 6)
3. **Measure** — run `bash scripts/analyze_structure.sh <project-path>`, then `bash scripts/estimate_tokens.sh <dir>` on each candidate source directory. **Stop here:** present the measurements table (format: references/templates.md) and confirm with the user before creating any files.
4. **Decide placements** — apply the Node Thresholds below.
5. **Execute**:
   - No root file → create root `AGENTS.md` from references/templates.md.
   - Root file exists → add the Intent Layer section (read-first directive + downlinks) from references/templates.md.
   - Create child nodes where measurements warrant; follow the patterns in references/node-examples.md.
   - Validate: one root file, read-first directive present, each node under 4k tokens (`bash scripts/estimate_tokens.sh <node-file>`).
6. **Maintain** (state `complete`) — ask the user which to run:
   - a) Audit nodes → interview with references/capture-protocol.md
   - b) Find candidates → re-run steps 3-4 and suggest new nodes
   - c) Both

## Node Thresholds

| Directory size | Action                   |
|----------------|--------------------------|
| <20k tokens    | No node needed           |
| 20-64k tokens  | Create a 2-3k token node |
| >64k tokens    | Split into child nodes   |

Beyond size, create a child node when a directory has a clear responsibility shift or hidden contracts/invariants. Place cross-cutting facts at the lowest common ancestor. Do NOT create nodes for every directory, simple utilities, or test folders (unless complex).

## Capture Questions

Document existing code by interviewing the user with the SME protocol in references/capture-protocol.md (questions, summarization rules, quality checklist).

## Resources

Run all scripts with `bash` (they are not executable directly).

- `scripts/detect_state.sh` — report Intent Layer state: `none` / `partial` / `complete`
- `scripts/analyze_structure.sh` — map semantic boundaries and candidate node locations
- `scripts/estimate_tokens.sh` — token estimate for a directory or a single node file
- `references/templates.md` — root and child node templates, measurements table format
- `references/node-examples.md` — real-world node examples, compression patterns
- `references/capture-protocol.md` — SME interview protocol and node quality checklist

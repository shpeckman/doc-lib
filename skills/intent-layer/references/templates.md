# Intent Layer Templates

## Root Context Template

Add to `AGENTS.md` at project root:

```markdown
## Intent Layer

**Before modifying code in a subdirectory, read its AGENTS.md first** to understand local patterns and invariants.

- **[Area 1]**: `path/to/AGENTS.md` - Brief description
- **[Area 2]**: `path/to/AGENTS.md` - Brief description

### Global Invariants

- [Invariant that applies across all areas]
- [Another global invariant]
```

The bolded line is the read-first directive — required in every root node.

## Child Node Template

Each `AGENTS.md` in a subdirectory:

```markdown
# {Area Name}

## Purpose
[1-2 sentences: what this area owns, what it explicitly doesn't do]

## Entry Points
- `main_api.ts` - Primary API surface
- `cli.ts` - CLI commands

## Contracts & Invariants
- All DB calls go through `./db/client.ts`
- Never import from `./internal/` outside this directory

## Patterns
To add a new endpoint:
1. Create handler in `./handlers/`
2. Register in `./routes.ts`
3. Add types to `./types.ts`

## Anti-patterns
- Never call external APIs directly; use `./clients/`
- Don't bypass validation layer

## Related Context
- Database layer: `./db/AGENTS.md`
- Shared utilities: `../shared/AGENTS.md`
```

## Measurements Table Format

Present this table before creating nodes (workflow step 3). Fill "Needs Node?" using the Node Thresholds in SKILL.md.

```
| Directory        | Tokens | Threshold | Needs Node? |
|------------------|--------|-----------|-------------|
| src/components   | ~30k   | 20-64k    | YES (2-3k)  |
| src/pages        | ~22k   | 20-64k    | YES (2-3k)  |
| src/lib          | ~8k    | <20k      | NO          |
```

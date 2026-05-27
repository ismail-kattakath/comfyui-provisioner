---
name: diffing-structured-data
description: Use the `diff` MCP tool (server name "diff", launched via `npx -y diff-mcp`) to compare two pieces of text or structured data (JSON, YAML, TOML, XML, HTML, plain text) and get a readable diff. Trigger when the user asks to compare configs, API responses, JSON objects, YAML files, schemas, or any two structured documents; when they say "diff", "compare", "what changed", "show differences", or "contrast these".
---

## Tool

Server: `diff` (MCP) — one tool: `diff`

```json
{
  "tool": "diff",
  "left": "<left content>",
  "leftFormat": "json5",
  "right": "<right content>",
  "rightFormat": "json5",
  "outputFormat": "text"
}
```

## Parameters

| Param | Type | Default | Notes |
|-------|------|---------|-------|
| `left` | string \| array \| object | required | Left-side content |
| `leftFormat` | string | `json5` | `text`, `json`, `json5`, `yaml`, `toml`, `xml`, `html` |
| `right` | string \| array \| object | required | Right-side content |
| `rightFormat` | string | `json5` | Same options as `leftFormat` |
| `outputFormat` | string | `text` | `text`, `json`, `jsonpatch` |

Pass structured data as a JSON object/array directly (not as a string) when possible — the tool accepts native JS objects. Pass everything else as a string.

## Format Selection

### Input format (`leftFormat` / `rightFormat`)
- Omit or use `json5` when input is JSON or JSON5 (comments, trailing commas allowed)
- Use `yaml` for YAML config files
- Use `toml` for TOML config files
- Use `xml` for XML documents
- Use `html` for HTML markup
- Use `text` for plain text, log files, prose

### Output format (`outputFormat`)
- **`text`** (default) — human-readable colored diff; best for displaying to users
- **`json`** — jsondiffpatch delta format; best when the agent needs to interpret or process the diff programmatically (see [delta-format.md](references/delta-format.md))
- **`jsonpatch`** — RFC 6902 JSON Patch array; best when the result will be used to apply changes to a system that supports JSON Patch

## When to Use Each Output Format

Use `text` when:
- Presenting the diff to the user for reading
- Showing what changed in logs, configs, or API responses

Use `json` when:
- Extracting which fields changed (parse the delta to find added/modified/deleted keys)
- Programmatically determining if specific paths changed
- Building logic that branches on diff results

Use `jsonpatch` when:
- The result will be fed to an API or system accepting RFC 6902 patches
- Generating patches to apply to another document

## Quick Examples

### Compare two JSON objects
```json
{
  "left": {"version": "1.0", "debug": false, "timeout": 30},
  "right": {"version": "1.1", "debug": true, "timeout": 30, "retries": 3},
  "outputFormat": "text"
}
```

### Compare YAML config files
```json
{
  "left": "database:\n  host: localhost\n  port: 5432\n  pool: 5\n",
  "leftFormat": "yaml",
  "right": "database:\n  host: db.prod.example.com\n  port: 5432\n  pool: 20\n",
  "rightFormat": "yaml",
  "outputFormat": "text"
}
```

### Get machine-readable delta for API responses
```json
{
  "left": {"status": "ok", "count": 42, "items": ["a", "b"]},
  "right": {"status": "ok", "count": 43, "items": ["a", "b", "c"]},
  "outputFormat": "json"
}
```
Returns delta: `{"count": [42, 43], "items": {"_t": "a", 2: [["c"]]}}`

### Cross-format comparison (YAML vs TOML)
```json
{
  "left": "name = \"myapp\"\nversion = \"2.0\"\n",
  "leftFormat": "toml",
  "right": "name: myapp\nversion: '3.0'\n",
  "rightFormat": "yaml",
  "outputFormat": "text"
}
```

### Generate a JSON Patch
```json
{
  "left": {"a": 1, "b": 2},
  "right": {"a": 1, "b": 3, "c": 4},
  "outputFormat": "jsonpatch"
}
```
Returns: `[{"op": "replace", "path": "/b", "value": 3}, {"op": "add", "path": "/c", "value": 4}]`

## Reading the Text Output

The text output uses +/- markers:
- Lines starting with `+` — added in right
- Lines starting with `-` — removed from left
- Unchanged lines are shown for context
- Property names shown with `modified`, `added`, `deleted` labels for structured data

## Detecting No Changes

If the diff returns an empty result or reports "no differences", the two inputs are identical (after parsing). This is useful for change detection in CI pipelines or monitoring tasks.

## References

- [Delta format explained](references/delta-format.md) — interpret `json` output: added, modified, deleted, array moves, text diffs
- [Practical examples](references/examples.md) — API responses, config files, JSON schema drift, YAML comparisons

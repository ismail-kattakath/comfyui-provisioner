# Tool Reference: json-yaml-toml MCP Server

Complete parameter reference for all tools. MCP server name: `json-yaml-toml`.

## `data` — Get, Set, Delete

**Signature:** `data(file_path, operation, key_path?, value?, value_type?, data_type?, return_type?, output_format?, cursor?)`

| Parameter | Type | Required | Values / Notes |
|-----------|------|----------|----------------|
| `file_path` | string | Yes | Absolute or relative path to file |
| `operation` | enum | Yes | `get` \| `set` \| `delete` |
| `key_path` | string | No* | Dot-separated path: `project.name`, `servers[0].host` |
| `value` | string | No* | Required for `set`; interpretation set by `value_type` |
| `value_type` | enum | No | `string` \| `number` \| `boolean` \| `null` \| `json` (default: `json`) |
| `data_type` | enum | No | `data` (default) \| `schema` \| `meta` |
| `return_type` | enum | No | `all` (default) \| `keys` (structure only) |
| `output_format` | enum | No | `json` \| `yaml` \| `toml` |
| `cursor` | string | No | Pagination cursor from previous response |

`key_path` is required for `set` and `delete`; optional for `get` (omit to get root).

**Returns:** `DataResponse | MutationResponse | SchemaResponse | ServerInfoResponse`

```json
{"success": true, "result": <any>, "file": "/abs/path", "format": "yaml"}
```

**value_type guide:**
- `json` (default): `value` is JSON-parsed. Use `"\"hello\""` for strings.
- `string`: `value` is treated as literal text. Use `"hello"` directly.
- `number`: `value` parsed as number. `"42"` → `42`
- `boolean`: `value` parsed as bool. `"true"` → `true`
- `null`: ignores `value`, sets key to null

**Schema enforcement:** When a schema is associated with the file, `set` and `delete` validate the resulting document before writing. Write is rejected on schema violation.

---

## `data_query` — Read-Only Expressions

**Signature:** `data_query(file_path, expression, output_format?, cursor?)`

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `file_path` | string | Yes | Source file |
| `expression` | string | Yes | yq v4 / jq-compatible expression |
| `output_format` | enum | No | `json` \| `yaml` \| `toml` (defaults to input format) |
| `cursor` | string | No | Pagination cursor |

**Returns:** `DataResponse` — read-only, no file modification.

**yq expression quick reference:**

| Expression | Effect |
|-----------|--------|
| `.` | Root object |
| `.field` | Access field |
| `.a.b.c` | Nested access |
| `.arr[]` | All array items |
| `.arr[0]` | First item |
| `.arr[-1]` | Last item |
| `\| keys` | Object keys as array |
| `\| length` | Count |
| `\| select(.x == "y")` | Filter |
| `\| map(expr)` | Transform array |
| `\| sort_by(.field)` | Sort |
| `\| unique` | Deduplicate |
| `to_entries \| map(...)` \| `from_entries` | Key-value transforms |

---

## `data_schema` — Schema Management

**Signature:** `data_schema(action, file_path?, schema_path?, schema_url?, schema_name?, search_paths?, path?, name?, uri?, max_depth?)`

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `action` | enum | Yes | `validate` \| `associate` \| `disassociate` \| `scan` \| `add_dir` \| `add_catalog` \| `list` |
| `file_path` | string | No* | For `validate`, `associate`, `disassociate` |
| `schema_path` | string | No | Local schema file path (for `validate`) |
| `schema_url` | string | No | Schema URL (for `associate`) |
| `schema_name` | string | No | Catalog schema name (for `associate`) |
| `search_paths` | array | No* | Directories to scan (for `scan`) |
| `path` | string | No* | Directory path (for `add_dir`) |
| `name` | string | No* | Catalog name (for `add_catalog`) |
| `uri` | string | No* | Catalog URI (for `add_catalog`) |
| `max_depth` | int | No | Default `5` (for `scan`) |

**Actions:**
- `validate`: Check syntax and, if schema found/provided, validate against it
- `associate`: Bind file to schema by `schema_name` (catalog lookup) or `schema_url`
- `disassociate`: Remove file's schema binding
- `scan`: Recursively find schema directories under `search_paths`
- `add_dir`: Add custom directory to schema search path
- `add_catalog`: Register custom JSON Schema catalog
- `list`: Show current schema config (dirs, catalogs, associations)

---

## `data_convert` — Format Conversion

**Signature:** `data_convert(file_path, output_format, output_file?)`

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `file_path` | string | Yes | Source file |
| `output_format` | enum | Yes | `json` \| `yaml` \| `toml` |
| `output_file` | string | No | Write result here; returns content if omitted |

**Supported conversions:**

| Source → Target | Supported |
|----------------|-----------|
| JSON → YAML | Yes |
| JSON → TOML | **No** |
| YAML → JSON | Yes |
| YAML → TOML | **No** |
| TOML → JSON | Yes |
| TOML → YAML | Yes |

Conversion to TOML is unsupported due to yq's encoder limitations for nested structures.

---

## `data_merge` — Deep Merge

**Signature:** `data_merge(file_path1, file_path2, output_format?, output_file?)`

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `file_path1` | string | Yes | Base file |
| `file_path2` | string | Yes | Overlay file (values override base) |
| `output_format` | enum | No | Defaults to format of `file_path1` |
| `output_file` | string | No | Write result; returns content if omitted |

Cross-format merging supported (e.g. TOML base + YAML overlay).

---

## `data_diff` — Structured Diff

**Signature:** `data_diff(file_path1, file_path2, ignore_order?)`

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `file_path1` | string | Yes | Base file |
| `file_path2` | string | Yes | Comparison file |
| `ignore_order` | bool | No | Default `false`; ignores list ordering when `true` |

Cross-format diff supported (e.g. JSON vs YAML). Returns `DiffResponse` with `has_differences`, `differences`, `statistics`, and `summary`.

---

## `constraint_validate` — LMQL Input Validation

**Signature:** `constraint_validate(constraint_name, value)`

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `constraint_name` | string | Yes | E.g. `YQ_PATH`, `INT`, `CONFIG_FORMAT` |
| `value` | string | Yes | Value to validate |

**Returns:** `{valid, constraint, value, error?, is_partial?, remaining_pattern?, suggestions?}`

Use `is_partial=true` to detect partially valid inputs that need more characters.

---

## `constraint_list` — List Constraints

**Signature:** `constraint_list()` — no parameters.

Returns all registered LMQL constraints with names, descriptions, patterns, and examples.

---

## Response envelope

All tools return JSON with:

```json
{
  "success": true,
  "result": "<data or null>",
  "file": "/absolute/path/to/file",
  "format": "json|yaml|toml",
  "cursor": "<next-page token or null>"
}
```

Errors: `{"success": false, "error": "message", ...}`

## Format auto-detection

`.json` → JSON | `.yaml`/`.yml` → YAML | `.toml` → TOML | `.jsonc` → JSONC (read-only; writes strip comments)

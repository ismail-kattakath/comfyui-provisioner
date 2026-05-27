---
name: editing-structured-data
description: >
  Use the json-yaml-toml MCP server (mcp__json-yaml-toml__*) to read, query,
  write, validate, convert, merge, and diff JSON, YAML, TOML, and JSONC files.
  Trigger when editing package.json, pyproject.toml, tsconfig.json, YAML CI
  configs, docker-compose files, or any structured data file where schema
  validation, comment preservation, or token-efficient access matters. Prefer
  these tools over Read/Write/Edit for all structured data files.
---

# Editing Structured Data

Use `mcp__json-yaml-toml__*` tools for all JSON, YAML, TOML, and JSONC
interactions. These tools are token-efficient, schema-aware, and safe-write
enforced. They use the MCP server named `json-yaml-toml` (launched via
`uvx mcp-json-yaml-toml`).

## When to use this server (not Read/Write/Edit)

- Reading specific fields from large config files (saves 20-40% tokens)
- Setting/deleting values while preserving comments and formatting
- Validating against JSON Schema before committing changes
- Converting between JSON, YAML, TOML formats
- Deep-merging config files (e.g. base + environment overlay)
- Diffing two config files across formats

## Core tools at a glance

| Tool | Purpose | Side effects |
|------|---------|--------------|
| `data` | get/set/delete at a key path | Writes on set/delete |
| `data_query` | yq/jq expressions for extraction | None (read-only) |
| `data_schema` | validate, associate, scan schemas | Writes associations |
| `data_convert` | convert between JSON/YAML/TOML | Optional write |
| `data_merge` | deep merge two files | Optional write |
| `data_diff` | structured diff two files | None (read-only) |
| `constraint_validate` | validate LMQL constraint inputs | None |
| `constraint_list` | list available constraints | None |

## Reading data

**Get a single value:**
```
data(file_path="pyproject.toml", operation="get", key_path="project.version")
```

**Get the full file as JSON:**
```
data(file_path="config.yaml", operation="get", output_format="json")
```

**Get only the top-level key names:**
```
data(file_path="package.json", operation="get", return_type="keys")
```

**Complex query with yq expression:**
```
data_query(file_path=".github/workflows/ci.yml", expression=".jobs | keys")
```

## Writing data

**Set a string value (use value_type to avoid JSON parsing issues):**
```
data(file_path="config.yaml", operation="set",
     key_path="app.name", value="my-app", value_type="string")
```

**Set a number:**
```
data(file_path="config.json", operation="set",
     key_path="server.port", value="8080", value_type="number")
```

**Set a boolean:**
```
data(file_path="settings.toml", operation="set",
     key_path="features.experimental", value="true", value_type="boolean")
```

**Set null:**
```
data(file_path="config.yaml", operation="set",
     key_path="legacy_field", value_type="null")
```

**Delete a key:**
```
data(file_path="package.json", operation="delete", key_path="scripts.prepublish")
```

Writes are **automatically schema-validated** if a schema is associated or
auto-detected. The write is rejected if validation fails.

## Schema validation workflow

1. Validate a file's syntax + schema:
   ```
   data_schema(action="validate", file_path=".eslintrc.json")
   ```

2. Manually associate a schema (use when auto-detection misses it):
   ```
   data_schema(action="associate", file_path=".gitlab-ci.yml",
               schema_name="gitlab-ci")
   ```
   Or by URL:
   ```
   data_schema(action="associate", file_path="custom.yaml",
               schema_url="https://example.com/schema.json")
   ```

3. List current schema configuration:
   ```
   data_schema(action="list")
   ```

See `references/schema-validation.md` for the full auto-detection priority chain.

## Format-specific notes

**YAML:**
- Comments and indentation are preserved on write
- YAML anchors are auto-generated for duplicate structures when `YAML_ANCHOR_OPTIMIZATION=true`
- Use `data_query` with yq expressions for multi-document YAML

**TOML:**
- Comments preserved via `tomlkit` (not yq) on write
- Conversion TO TOML is not supported — yq cannot encode complex nested
  structures. Use TOML only as a source format.
- Integer, float, datetime, and boolean types are preserved

**JSONC:**
- Read, query, and schema-validate are fully supported
- Write operations strip comments (library limitation); warn the user before
  writing to `.jsonc` files

**JSON:**
- Standard JSON only (no comments); use JSONC extension for commented JSON

## Converting and merging

**Convert TOML to YAML:**
```
data_convert(file_path="pyproject.toml", output_format="yaml")
```

**Deep merge base + overlay:**
```
data_merge(file_path1="base.yaml", file_path2="production.yaml",
           output_file="merged.yaml")
```

**Diff two configs:**
```
data_diff(file_path1="old-config.json", file_path2="new-config.json")
```

## Pagination

For files >10KB the response includes a `cursor`. Pass it back:
```
data(file_path="large.json", operation="get", cursor="<cursor from response>")
```

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `MCP_CONFIG_FORMATS` | `json,yaml,toml` | Enable/disable formats |
| `MCP_SCHEMA_CACHE_DIRS` | `~/.cache/mcp-json-yaml-toml` | Schema search paths |
| `YAML_ANCHOR_OPTIMIZATION` | `true` | Auto-generate YAML anchors |

## References

- [references/tools.md](references/tools.md) — complete parameter reference for every tool
- [references/schema-validation.md](references/schema-validation.md) — schema discovery, binding, and validation details
- [references/examples.md](references/examples.md) — practical examples for common file types

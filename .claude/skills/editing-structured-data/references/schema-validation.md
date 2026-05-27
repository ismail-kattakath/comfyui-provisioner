# Schema Validation Reference

## Auto-Detection Priority Chain

The server resolves schemas in this order (first match wins):

1. **File directives** — inline comments/keys in the file itself
   - YAML: `# yaml-language-server: $schema=https://...`
   - TOML: `#:schema https://...`
   - JSON/YAML: `$schema` key at root
   - TOML: `"$schema"` quoted key at root

2. **Manual association** — bindings set via `data_schema(action="associate", ...)`

3. **VS Code / Cursor local cache** — reads `.vscode/settings.json` and extension caches for `json.schemas` / `yaml.schemas` entries

4. **SchemaStore.org glob matching** — auto-matches file path against thousands of known patterns (e.g. `package.json`, `.github/workflows/*.yml`, `pyproject.toml`)

---

## Validating a File

```
data_schema(action="validate", file_path="config.json")
```

Response fields:
- `syntax_valid` — file parses correctly
- `schema_validated` — passed JSON Schema validation (only if schema found)
- `schema_file` — path to the schema used
- `schema_message` — human-readable result
- `overall_valid` — `syntax_valid AND (schema_validated if schema exists)`

Provide an explicit schema to override auto-detection:
```
data_schema(action="validate", file_path="config.yaml",
            schema_path="/path/to/myschema.json")
```

---

## Associating a Schema

**By catalog name** (SchemaStore.org or custom catalog):
```
data_schema(action="associate", file_path=".gitlab-ci.yml",
            schema_name="gitlab-ci")
```

**By URL:**
```
data_schema(action="associate", file_path="custom-config.yaml",
            schema_url="https://raw.githubusercontent.com/org/repo/main/schema.json")
```

**Remove association:**
```
data_schema(action="disassociate", file_path=".gitlab-ci.yml")
```

---

## Schema Enforcement on Write

When `data(operation="set")` or `data(operation="delete")` is called and a schema
is associated (or auto-detected), the server:

1. Applies the requested mutation in memory
2. Validates the resulting document against the schema
3. Writes to disk only if validation passes
4. Returns an error with violation details if validation fails

This means writes are always schema-safe — no partially-written invalid files.

---

## Discovering Schemas Locally

Scan a directory tree for JSON Schema files:
```
data_schema(action="scan", search_paths=["/home/user/.config", "/project"],
            max_depth=3)
```

Add a directory to the persistent schema search path:
```
data_schema(action="add_dir", path="/project/.schemas")
```

List current config (dirs, catalogs, associations):
```
data_schema(action="list")
```

---

## Custom Schema Catalogs

Register a custom catalog (a JSON file listing schemas with name + url):
```
data_schema(action="add_catalog", name="my-company",
            uri="https://schemas.example.com/catalog.json")
```

Catalog format (JSON Schema Store compatible):
```json
{
  "schemas": [
    {
      "name": "my-service-config",
      "description": "My service configuration",
      "fileMatch": ["service-config.yaml"],
      "url": "https://schemas.example.com/service-config.json"
    }
  ]
}
```

---

## Common SchemaStore Schema Names

| File | Schema name |
|------|-------------|
| `.github/workflows/*.yml` | `github-workflow` |
| `.gitlab-ci.yml` | `gitlab-ci` |
| `package.json` | `package` |
| `tsconfig.json` | `tsconfig` |
| `docker-compose*.yml` | `compose` |
| `pyproject.toml` | `pyproject` |
| `.eslintrc.json` | `eslintrc` |
| `renovate.json` | `renovate` |
| `dependabot.yml` | `dependabot` |
| `helm values.yaml` | `helm-values` |

---

## Adding Schema Directives to Files

Instead of using `associate`, embed the schema in the file so it's always detected.

**YAML:**
```yaml
# yaml-language-server: $schema=https://json.schemastore.org/github-workflow.json
name: CI
on: [push]
```

**JSON:**
```json
{
  "$schema": "https://json.schemastore.org/package.json",
  "name": "my-package"
}
```

**TOML:**
```toml
#:schema https://json.schemastore.org/pyproject.json
[project]
name = "my-project"
```

---

## SchemaStore.org Assets

The server fetches missing schemas from `https://www.schemastore.org/api/json/catalog.json`
and caches them locally at `~/.cache/mcp-json-yaml-toml/` (configurable via
`MCP_SCHEMA_CACHE_DIRS`). No data leaves your machine — only schema files are
downloaded, not your config files.

The `yq` binary is also auto-downloaded if missing (stored in the same cache dir).

---

## Troubleshooting Schema Issues

**Schema not found:**
1. Run `data_schema(action="list")` to see current config
2. Run `data_schema(action="validate", file_path="...")` to see what the server detects
3. Use `data_schema(action="associate", ...)` to manually bind
4. Check `MCP_SCHEMA_CACHE_DIRS` if using custom schemas

**Validation fails on write:**
- The error response includes which schema constraint was violated
- Use `data_schema(action="validate", ...)` to inspect issues before writing
- Use `data_schema(action="disassociate", ...)` temporarily if you need to bypass validation
  (not recommended — fix the schema or data instead)

**Wrong schema auto-detected:**
- Disassociate and re-associate with the correct schema name/URL
- Or add a `$schema` / `# yaml-language-server` directive to the file

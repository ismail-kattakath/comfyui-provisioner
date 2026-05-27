# Practical Examples

## package.json

```
# Read version
data(file_path="package.json", operation="get", key_path="version")

# Bump version
data(file_path="package.json", operation="set",
     key_path="version", value="2.1.0", value_type="string")

# Add dependency
data(file_path="package.json", operation="set",
     key_path="dependencies.zod", value="^3.22.0", value_type="string")

# List all dependency names
data_query(file_path="package.json", expression=".dependencies | keys")

# Find deps pinned to major 1.x
data_query(file_path="package.json",
           expression='.dependencies | to_entries | map(select(.value | startswith("^1."))) | from_entries')

# Remove deprecated script
data(file_path="package.json", operation="delete", key_path="scripts.prepublish")

# Validate (SchemaStore auto-detects package.json)
data_schema(action="validate", file_path="package.json")
```

---

## pyproject.toml

```
# Read project name
data(file_path="pyproject.toml", operation="get", key_path="project.name")

# Set minimum Python version
data(file_path="pyproject.toml", operation="set",
     key_path="project.requires-python", value=">=3.11", value_type="string")

# Add dependencies (array)
data(file_path="pyproject.toml", operation="set",
     key_path="project.dependencies",
     value='["requests>=2.28", "httpx>=0.24"]', value_type="json")

# Read dev dependencies
data_query(file_path="pyproject.toml", expression='."dependency-groups".dev')

# Convert to YAML for inspection (TOML→YAML supported, reverse is not)
data_convert(file_path="pyproject.toml", output_format="yaml")

# Validate
data_schema(action="associate", file_path="pyproject.toml", schema_name="pyproject")
data_schema(action="validate", file_path="pyproject.toml")
```

---

## tsconfig.json

```
# Read target
data(file_path="tsconfig.json", operation="get", key_path="compilerOptions.target")

# Enable strict mode
data(file_path="tsconfig.json", operation="set",
     key_path="compilerOptions.strict", value="true", value_type="boolean")

# Add path alias
data(file_path="tsconfig.json", operation="set",
     key_path='compilerOptions.paths.@lib/*',
     value='["./src/lib/*"]', value_type="json")

# List all compiler option keys
data(file_path="tsconfig.json", operation="get",
     key_path="compilerOptions", return_type="keys")

# Validate (auto-detected by SchemaStore)
data_schema(action="validate", file_path="tsconfig.json")
```

---

## GitHub Actions YAML

```
# Read triggers
data(file_path=".github/workflows/ci.yml", operation="get", key_path="on")

# List job names
data_query(file_path=".github/workflows/ci.yml", expression=".jobs | keys")

# Get all step names in a job
data_query(file_path=".github/workflows/ci.yml",
           expression='.jobs.build.steps[].name')

# Add secret env var to deploy job
data(file_path=".github/workflows/ci.yml", operation="set",
     key_path="jobs.deploy.env.DATABASE_URL",
     value='${{ secrets.DATABASE_URL }}', value_type="string")

# Associate and validate
data_schema(action="associate", file_path=".github/workflows/ci.yml",
            schema_name="github-workflow")
data_schema(action="validate", file_path=".github/workflows/ci.yml")
```

---

## docker-compose.yml

```
# List services
data_query(file_path="docker-compose.yml", expression=".services | keys")

# Set image tag
data(file_path="docker-compose.yml", operation="set",
     key_path="services.api.image", value="myapp:v2.0", value_type="string")

# Add env var to service
data(file_path="docker-compose.yml", operation="set",
     key_path="services.api.environment.LOG_LEVEL", value="debug", value_type="string")

# Get all port mappings
data_query(file_path="docker-compose.yml", expression=".services[].ports[]")
```

---

## .gitlab-ci.yml

```
data_schema(action="associate", file_path=".gitlab-ci.yml", schema_name="gitlab-ci")
data_schema(action="validate", file_path=".gitlab-ci.yml")
data(file_path=".gitlab-ci.yml", operation="get", key_path="stages")
data_query(file_path=".gitlab-ci.yml", expression=". | keys")
data(file_path=".gitlab-ci.yml", operation="set",
     key_path="default.image", value="python:3.11-slim", value_type="string")
```

---

## Merging, diffing, pagination

```
# Merge base + overlay (second file wins on conflict)
data_merge(file_path1="config/base.yaml", file_path2="config/production.yaml",
           output_file="config/merged.yaml")

# Cross-format merge (TOML + YAML overlay → JSON)
data_merge(file_path1="base.toml", file_path2="override.yaml", output_format="json")

# Diff (cross-format supported)
data_diff(file_path1="config.v1.yaml", file_path2="config.v2.yaml")
data_diff(file_path1="old.json", file_path2="new.json", ignore_order=True)

# Pagination: pass cursor from response for files >10KB
data(file_path="large.json", operation="get", cursor="<cursor from prev response>")
```

---

## Token-efficient large file access

```
# Extract only mcpServers from ~/.claude.json — ~22% fewer tokens, ~43% faster
data_query(file_path="~/.claude.json", expression=".mcpServers")
data_query(file_path="~/.claude.json", expression='.mcpServers["json-yaml-toml"]')
```

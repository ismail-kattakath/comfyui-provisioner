---
name: querying-json-with-jq
description: Use when the agent needs to query, filter, transform, validate, or inspect JSON data using jq syntax. Triggers on "query JSON", "filter JSON", "extract from JSON", "jq filter", "parse JSON file", "validate JSON", "prettify JSON", "get JSON keys", or whenever jq expressions are needed to process structured data.
---

# Querying JSON with jq (mcp-jq)

## MCP Server

Server name: `mcp-jq` — launched via `npx @247arjun/mcp-jq`. Requires `jq` installed on the system (`brew install jq` / `apt-get install jq`). Uses stdio transport.

Add to `.mcp.json`:
```json
{
  "mcpServers": {
    "mcp-jq": {
      "command": "npx",
      "args": ["@247arjun/mcp-jq"]
    }
  }
}
```

## Available Tools

| Tool | Purpose | Key Parameters |
|------|---------|----------------|
| `jq_query` | Query inline JSON string | `json_data`, `filter`, `raw_output?` |
| `jq_query_file` | Query a JSON file on disk | `file_path`, `filter`, `raw_output?` |
| `jq_format` | Prettify/indent compact JSON | `json_data` |
| `jq_validate` | Check if a string is valid JSON | `json_data` |
| `jq_keys` | List top-level or all nested keys | `json_data`, `recursive?` |

## When to Use Each Tool

**`jq_query`** — agent has JSON as a string in context and needs to extract or transform it without writing to disk.

**`jq_query_file`** — JSON lives in a file; avoids reading the whole file into memory first; better for large files.

**`jq_format`** — received minified JSON (e.g., from an API) and need to display it readably or before further inspection.

**`jq_validate`** — received a string that should be JSON; validate before passing to other tools to avoid parse errors. Note: uses JavaScript's `JSON.parse` internally, not jq binary.

**`jq_keys`** — exploring unknown JSON structure; use `recursive: true` to see all nested keys across the entire document.

## Tool Parameters

### jq_query
```
json_data  (string, required)  — JSON string to query
filter     (string, required)  — jq filter expression
raw_output (boolean, optional) — strip JSON quotes from string output; default false
```

### jq_query_file
```
file_path  (string, required)  — absolute or relative path to .json file
filter     (string, required)  — jq filter expression
raw_output (boolean, optional) — strip JSON quotes from string output; default false
```

### jq_format
```
json_data  (string, required)  — compact or malformatted JSON string
```

### jq_validate
```
json_data  (string, required)  — string to test for JSON validity
```

### jq_keys
```
json_data  (string, required)  — JSON object or array of objects
recursive  (boolean, optional) — if true, walks entire tree; default false
```
Internally uses `keys` (non-recursive) or `.. | keys?` (recursive).

## Essential jq Filters

### Field access and identity
```
.                          # identity — return input unchanged
.name                      # field access
.user.email                # nested field
.items[0]                  # first array element
.items[-1]                 # last element
.items[1:3]                # slice (index 1 up to but not including 3)
.foo?                      # optional — suppress error if field missing
```

### Array and object iteration
```
.[]                        # iterate all elements
.[].name                   # field from each element
keys                       # sorted array of object keys
values                     # array of object values
length                     # count of array elements or string length
```

### Filtering
```
.[] | select(.active == true)
.[] | select(.age > 25 and .role == "admin")
.[] | select(.tags | contains(["urgent"]))
.[] | select(.name | startswith("A"))
```

### Transformation
```
map(.name)                 # extract field from each element
map(select(.active))       # filter array
map({id, name})            # shorthand object construction (keep named fields)
map({user: .name, email})  # rename + keep
[.[] | .price * .qty]      # compute new values
```

### Aggregation
```
map(.salary) | add               # sum
map(.salary) | add / length      # average
map(.salary) | max               # max value
map(.salary) | min               # min value
length                           # count
[.[] | .name] | unique           # deduplicate
sort_by(.name)                   # sort array of objects
sort_by(.score) | reverse        # sort descending
group_by(.city)                  # group into arrays by field value
```

### Object construction
```
{name: .name, city: .address.city}     # build new object
. + {status: "active"}                  # merge/add field
del(.password)                          # remove field
with_entries(select(.value != null))    # filter object entries
```

### String operations
```
"Hello, \(.name)!"         # string interpolation
.name | ascii_downcase
.name | split(" ") | .[0]  # first word
[.name, .role] | join(", ")
```

### Conditional and error handling
```
if .status == "active" then "yes" else "no" end
.value // "default"        # alternative operator (use when null)
try .foo catch "missing"   # catch errors
```

### Paths and recursive descent
```
..                         # recursive descent — all values
.. | strings               # all string values in document
.. | numbers               # all numeric values
path(.users[].name)        # path to a value
getpath(["users",0,"name"])
```

## Practical Patterns

**Count matching items:**
```
[.[] | select(.status == "error")] | length
```

**Pluck and reshape:**
```
.users[] | {id: .id, display: "\(.firstName) \(.lastName)"}
```

**Group and summarize:**
```
group_by(.department) | map({dept: .[0].department, count: length, avgSalary: (map(.salary) | add / length)})
```

**Extract unique field values:**
```
[.[].category] | unique | sort
```

**Flatten nested arrays:**
```
[.orders[].items[]] | flatten
```

## References

- [jq Filter Patterns](references/jq-filters.md) — complete filter reference with edge cases
- [Real-world Examples](references/examples.md) — tool call examples with realistic JSON inputs

# mcp-jq Real-World Usage Examples

## jq_validate — Validate before processing

```json
{
  "tool": "jq_validate",
  "arguments": {
    "json_data": "{\"status\": \"ok\", \"results\": []}"
  }
}
```
Returns `"✅ Valid JSON"` or `"❌ Invalid JSON: ..."` with parse error detail.

## jq_format — Prettify compact API response

```json
{
  "tool": "jq_format",
  "arguments": {
    "json_data": "{\"id\":42,\"name\":\"Alice\",\"roles\":[\"admin\",\"editor\"]}"
  }
}
```

## jq_keys — Explore unknown JSON structure

**Top-level keys:**
```json
{
  "tool": "jq_keys",
  "arguments": {
    "json_data": "{\"users\": [], \"meta\": {\"total\": 0}, \"page\": 1}"
  }
}
```
Returns: `["meta", "page", "users"]`

**All nested keys (recursive):**
```json
{
  "tool": "jq_keys",
  "arguments": {
    "json_data": "{\"user\": {\"profile\": {\"name\": \"Alice\", \"age\": 30}}}",
    "recursive": true
  }
}
```

## jq_query — Extract and transform inline JSON

**Simple field extraction:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "{\"database\": {\"host\": \"db.example.com\", \"port\": 5432}}",
    "filter": ".database.host"
  }
}
```

**Get all names from array:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"name\": \"Alice\", \"age\": 30}, {\"name\": \"Bob\", \"age\": 25}]",
    "filter": ".[].name"
  }
}
```

**Raw output — no quotes around strings:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"name\": \"Alice\"}, {\"name\": \"Bob\"}]",
    "filter": ".[].name",
    "raw_output": true
  }
}
```
Returns `Alice\nBob` instead of `"Alice"\n"Bob"`.

**Filter by condition:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"name\":\"Alice\",\"active\":true},{\"name\":\"Bob\",\"active\":false}]",
    "filter": "[.[] | select(.active == true) | .name]"
  }
}
```

**Reshape objects with string interpolation:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"first\":\"Alice\",\"last\":\"Smith\",\"dept\":\"Engineering\"}]",
    "filter": ".[] | {fullName: \"\(.first) \(.last)\", department: .dept}"
  }
}
```

**Group and aggregate:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"dept\":\"Eng\",\"salary\":120000},{\"dept\":\"Eng\",\"salary\":90000},{\"dept\":\"Design\",\"salary\":80000}]",
    "filter": "group_by(.dept) | map({dept: .[0].dept, count: length, avgSalary: (map(.salary) | add / length)})"
  }
}
```

**Safe access — suppress missing field errors:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"user\":{\"email\":\"a@b.com\"}},{\"user\":{}},{\"user\":{\"email\":\"c@d.com\"}}]",
    "filter": "[.[] | .user.email? // null]"
  }
}
```

## jq_query_file — Process files on disk

**Read config value / count records / filter:**
```json
{"tool":"jq_query_file","arguments":{"file_path":"/etc/myapp/config.json","filter":".database.host"}}
{"tool":"jq_query_file","arguments":{"file_path":"/var/data/orders.json","filter":"length"}}
{"tool":"jq_query_file","arguments":{"file_path":"/tmp/users.json","filter":"[.[] | select(.active)] | length"}}
```

**Extract high earners from nested data:**
```json
{
  "tool": "jq_query_file",
  "arguments": {
    "file_path": "/tmp/company.json",
    "filter": ".departments[] | .employees[] | select(.salary > 100000) | {name, role: .title, salary}"
  }
}
```

**Summarize error logs by code:**
```json
{
  "tool": "jq_query_file",
  "arguments": {
    "file_path": "/var/log/app-errors.json",
    "filter": "group_by(.errorCode) | map({code: .[0].errorCode, count: length, lastSeen: (map(.timestamp) | max)}) | sort_by(.count) | reverse"
  }
}
```

## Workflow: Inspect an Unknown JSON File

Use this sequence when structure is unfamiliar:

1. Validate: `jq_validate` with file contents
2. Top-level keys: `jq_keys` (non-recursive)
3. All nested keys: `jq_keys` with `recursive: true`
4. Format/read: `jq_format` to browse structure
5. Query: `jq_query_file` with targeted filter

## Output Formatting

**CSV rows via raw_output:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"name\":\"Alice\",\"score\":95},{\"name\":\"Bob\",\"score\":87}]",
    "filter": ".[] | [.name, (.score | tostring)] | join(\",\")",
    "raw_output": true
  }
}
```

**Markdown table rows:**
```json
{
  "tool": "jq_query",
  "arguments": {
    "json_data": "[{\"name\":\"Alice\",\"role\":\"Admin\"},{\"name\":\"Bob\",\"role\":\"User\"}]",
    "filter": ".[] | \"| \\(.name) | \\(.role) |\"",
    "raw_output": true
  }
}
```

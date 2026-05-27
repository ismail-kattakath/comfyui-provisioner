# Practical Examples for diff-mcp

All examples use the `diff` MCP tool from the `diff` server.

---

## 1. Comparing API Responses

Detect what changed between two API response snapshots.

**Tool call:**
```json
{
  "left": {
    "status": "ok",
    "user": {"id": 42, "name": "Alice", "role": "viewer"},
    "permissions": ["read"],
    "quota": 100
  },
  "right": {
    "status": "ok",
    "user": {"id": 42, "name": "Alice", "role": "admin"},
    "permissions": ["read", "write", "delete"],
    "quota": 500
  },
  "outputFormat": "json"
}
```

**Delta output:**
```json
{
  "user": {
    "role": ["viewer", "admin"]
  },
  "permissions": {
    "_t": "a",
    "1": [["write"]],
    "2": [["delete"]]
  },
  "quota": [100, 500]
}
```

**Interpretation:** `user.role` was elevated, two permissions were added to the array, quota tripled.

---

## 2. YAML Config File Comparison

Compare staging vs production config files.

**Tool call:**
```json
{
  "left": "server:\n  host: 0.0.0.0\n  port: 8080\n  workers: 2\nlogging:\n  level: debug\n  format: pretty\n",
  "leftFormat": "yaml",
  "right": "server:\n  host: 0.0.0.0\n  port: 8080\n  workers: 8\nlogging:\n  level: warn\n  format: json\n",
  "rightFormat": "yaml",
  "outputFormat": "text"
}
```

**Text output** shows:
```
 server
   workers: 2 => 8
 logging
   level: debug => warn
   format: pretty => json
```

Use `outputFormat: "text"` when showing the diff to a user for review.

---

## 3. JSON Schema Drift Detection

Check if an API schema changed between versions. Use `json` output to programmatically detect which fields were added/removed.

**Tool call:**
```json
{
  "left": {
    "type": "object",
    "required": ["id", "name"],
    "properties": {
      "id": {"type": "integer"},
      "name": {"type": "string"},
      "email": {"type": "string"}
    }
  },
  "right": {
    "type": "object",
    "required": ["id", "name", "email"],
    "properties": {
      "id": {"type": "integer"},
      "name": {"type": "string"},
      "email": {"type": "string", "format": "email"},
      "phone": {"type": "string"}
    }
  },
  "outputFormat": "json"
}
```

**Delta:**
```json
{
  "required": {
    "_t": "a",
    "2": [["email"]]
  },
  "properties": {
    "email": {
      "format": ["email"]
    },
    "phone": [{"type": "string"}]
  }
}
```

Breaking change detected: `email` is now required and has added format validation; `phone` is a new optional field.

---

## 4. Cross-Format Comparison (TOML vs YAML)

The tool normalizes each side to an object graph independently, so different input formats can be compared directly.

```json
{
  "left": "[package]\nname = \"myapp\"\nversion = \"2.1.0\"\n",
  "leftFormat": "toml",
  "right": "package:\n  name: myapp\n  version: 3.0.0\n",
  "rightFormat": "yaml",
  "outputFormat": "text"
}
```

---

## 5. Generating JSON Patch for an API

Compute a JSON Patch (RFC 6902) to apply an update to a remote resource.

**Tool call:**
```json
{
  "left": {"name": "Widget", "price": 9.99, "stock": 100, "active": true},
  "right": {"name": "Widget Pro", "price": 14.99, "stock": 100, "active": true, "sku": "WGT-PRO"},
  "outputFormat": "jsonpatch"
}
```

**Output:**
```json
[
  {"op": "replace", "path": "/name", "value": "Widget Pro"},
  {"op": "replace", "path": "/price", "value": 14.99},
  {"op": "add", "path": "/sku", "value": "WGT-PRO"}
]
```

Apply this patch with a `PATCH /products/123` request using `Content-Type: application/json-patch+json`.

---

## 6. XML, HTML, and Plain Text

XML/HTML: pass as string with `leftFormat: "xml"` or `"html"`. Plain text and logs: use `leftFormat: "text"` — the tool uses google-diff-match-patch for character-level diffing of long strings.

```json
{
  "left": "<config><timeout>30</timeout><retries>3</retries></config>",
  "leftFormat": "xml",
  "right": "<config><timeout>60</timeout><retries>5</retries><debug>true</debug></config>",
  "rightFormat": "xml",
  "outputFormat": "text"
}
```

---

## 7. Change Detection (No Diff = Identical)

Use the diff tool for equality checks: if the result contains no differences (empty delta `{}` in json mode, or empty text output), the inputs are equivalent after parsing.

```json
{
  "left": {"a": 1, "b": null},
  "right": "{\"b\": null, \"a\": 1}",
  "rightFormat": "json",
  "outputFormat": "json"
}
```

Returns `{}` — objects are identical regardless of key ordering or format differences.


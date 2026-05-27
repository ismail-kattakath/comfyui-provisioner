# jsondiffpatch Delta Format

The `json` output format from the `diff` tool returns a **delta** — a compact JSON representation of changes. Only changed properties/indices appear; unchanged values are omitted.

## Core Rules

- `undefined` → value = **added**
- value → `undefined` = **deleted**
- value → different value = **modified**
- Objects with inner changes retain their structure but only include changed properties
- Arrays use a special `_t: 'a'` marker and index notation

---

## Primitive Changes

### Added
Value did not exist on the left; now exists on the right.
```json
"fieldName": [newValue]
```
Example: `"retries": [3]` — `retries` was added with value `3`

### Modified
Value existed on both sides but changed.
```json
"fieldName": [oldValue, newValue]
```
Example: `"version": ["1.0", "1.1"]` — version changed from `"1.0"` to `"1.1"`

### Deleted
Value existed on the left; removed on the right.
```json
"fieldName": [oldValue, 0, 0]
```
Example: `"debug": [true, 0, 0]` — `debug` key was deleted (last two `0`s are the delete marker)

---

## Object with Nested Changes

Only changed properties appear. The structure mirrors the original object.

```json
{
  "database": {
    "host": ["localhost", "db.prod.example.com"],
    "pool": [5, 20]
  }
}
```
Means: inside `database`, `host` and `pool` were modified; `port` is unchanged and absent.

---

## Array Changes

Arrays produce a delta with `_t: 'a'` as the type marker.

```json
{
  "_t": "a",
  "2": [["c"]],
  "_1": [{"name": "Bob"}, 0, 0]
}
```

### Index notation

| Key format | Refers to | Used for |
|------------|-----------|----------|
| `"N"` (number) | Index in the **right** (new) array | Insertions |
| `"_N"` (underscore + number) | Index in the **left** (original) array | Deletions, moves |

### Inserted item
```json
"2": [newItem]
```
Item inserted at index 2 in the final array.

### Deleted item
```json
"_1": [oldItem, 0, 0]
```
Item at index 1 in the original array was removed.

### Modified item (object in array)
```json
"3": {
  "population": [1136286, 1137520]
}
```
Object at index 3 had its `population` field modified.

### Moved item
```json
"_4": ["", 2, 3]
```
- `""` — placeholder (moved item value suppressed by default)
- `2` — destination index in the right array
- `3` — magic number meaning "array move"

So `_4: ["", 2, 3]` = item that was at index 4 in original moved to index 2 in the result.

---

## Text Diffs

Short strings that changed produce a simple modified delta:
```json
"title": ["Hello", "Hello World"]
```

Long strings (default threshold: 60 chars on both sides) use a character-level diff algorithm (google-diff-match-patch):
```json
"description": ["@@ -1,15 +1,21 @@\n Hello \n-World\n+Universe\n", 0, 2]
```
- Index 0: the unidiff patch string
- Index 1: `0` (placeholder)
- Index 2: `2` — magic number meaning "text diff"

The unidiff format is a character-level variation: `@@ -start,length +start,length @@` with `-` (removed) and `+` (added) context lines.

---

## Complete Example

Input:
```json
left  = {"version": "1.0", "debug": false, "tags": ["alpha"], "meta": {"author": "Alice"}}
right = {"version": "1.1", "tags": ["alpha", "beta"], "meta": {"author": "Alice", "org": "Acme"}}
```

Delta (`json` output):
```json
{
  "version": ["1.0", "1.1"],
  "debug": [false, 0, 0],
  "tags": {
    "_t": "a",
    "1": [["beta"]]
  },
  "meta": {
    "org": ["Acme"]
  }
}
```

Reading it:
- `version` modified from `"1.0"` to `"1.1"`
- `debug` deleted (was `false`)
- `tags` array: item `"beta"` inserted at index 1
- `meta.org` added with value `"Acme"`
- `meta.author` unchanged (not in delta)

---

## Quick Reference Card

| Delta shape | Meaning |
|-------------|---------|
| `[val]` | Added (val is new value) |
| `[old, new]` | Modified |
| `[old, 0, 0]` | Deleted |
| `{ prop: delta, ... }` | Object with nested changes |
| `{ _t: 'a', N: delta, _N: delta }` | Array with changes |
| `["", destIdx, 3]` | Array item moved to destIdx |
| `[unidiff, 0, 2]` | Long string text diff |

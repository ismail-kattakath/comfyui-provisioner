# jq Filter Reference

## Identity and Field Access

```jq
.                        # return input as-is
.foo                     # field access
.foo.bar                 # nested field
.["foo"]                 # key with special chars
.[0]                     # first array element
.[-1]                    # last element
.[2:5]                   # slice indices 2,3,4
.foo?                    # suppress error if field missing
empty                    # produce no output (skip in conditionals)
```

## Types

```jq
type                     # "null","boolean","number","string","array","object"
arrays / objects / strings / numbers / booleans / nulls  # type filters
.[] | select(type == "object")
```

## Iteration

```jq
.[]                      # iterate elements or object values
keys                     # sorted array of keys (or indices)
keys_unsorted            # keys in insertion order
values                   # array of values
to_entries               # [{key, value}] pairs
from_entries             # inverse of to_entries
with_entries(f)          # to_entries | map(f) | from_entries
```

## Filtering with select

```jq
.[] | select(.active == true)
.[] | select(.count > 10)
.[] | select(.name != null)
.[] | select(.role == "admin" or .role == "owner")
.[] | select(.age >= 18 and .age < 65)
.[] | select(.tags | contains(["a","b"]))    # array contains all
.[] | select(.name | startswith("Error"))
.[] | select(.name | test("^[A-Z]"))         # regex test
```

## Transformation with map

```jq
map(.name)                       # extract field from each element
map(. * 2)                       # transform each value
map(select(.active))             # filter — keep only matching
map({id, name})                  # shorthand: keep named fields
map({user: .name, age})          # rename first, keep second
map(. + {processed: true})       # add field to each object
map(del(.password))              # remove field from each object
```

## Aggregation and Math

```jq
length                           # array/string length, object key count
add                              # sum numbers, concat strings/arrays
map(.price) | add                # sum a field
map(.price) | add / length       # average
map(.price) | max                # maximum value
map(.price) | min                # minimum value
sort / sort_by(.name)            # sort
sort_by(.score) | reverse        # descending
unique / unique_by(.name)        # deduplicate
floor / ceil / round / sqrt / fabs / pow(.; 2)
```

## Sorting and Grouping

```jq
sort_by(.last, .first)           # multi-field sort
group_by(.city)                  # group into arrays by field
group_by(.dept) | map({dept: .[0].dept, count: length})
flatten / flatten(1)             # flatten nested arrays
indices("x") / index("x")       # all/first indices of element
```

## Object Operations

```jq
. + {status: "active"}           # merge (right-side wins)
del(.password)                   # delete a key
del(.a, .b)                      # delete multiple keys
has("key")                       # check key exists
to_entries | map(select(.value != null)) | from_entries  # remove nulls
```

## String Operations

```jq
"Hello, \(.name)!"               # string interpolation
@base64 / @base64d               # encode/decode
@uri / @html / @csv / @tsv / @json
split(",") / join(", ")
ltrimstr("prefix") / rtrimstr(".json")
ascii_downcase / ascii_upcase
tostring / tonumber
test("regex")                    # boolean match
match("regex")                   # match object
capture("(?P<y>\\d{4})")        # named capture groups
scan("\\d+")                     # all matches
```

## Conditionals

```jq
if .status == "ok" then "yes" elif .status == "warn" then "maybe" else "no" end
.value // "default"              # use default if null or false
try .foo catch "fallback"        # catch errors
try (.x / .y) catch 0           # safe division
```

## Recursive Descent

```jq
..                               # all values, recursively
.. | strings                     # all string values anywhere
.. | .name? // empty             # all "name" fields at any depth
[.. | keys?] | flatten | unique  # all keys anywhere in document
```

## Paths

```jq
path(.a.b)                       # ["a","b"]
[paths]                          # all leaf paths
getpath(["a","b"])               # value at path
setpath(["a","b"]; 42)          # set value at path
delpaths([["a"],["b"]])         # delete multiple paths
```

## Reduce and Limiting

```jq
reduce .[] as $x (0; . + $x)                  # sum
reduce .[] as $x ({}; . + {($x.k): $x.v})     # build object
first(.[] | select(.active))                   # first match
last(.[] | select(.active))                    # last match
limit(3; .[] | select(.active))               # at most N results
until(. > 100; . * 2)                         # iterate until condition
nth(2; range(10))                              # 3rd value (0-indexed)
```

## Common Gotchas

- `select` returns `empty` (not false) — wrap in `[...]` or `map` to collect results
- `//` is alternative operator (null/false fallback), not logical OR — use `or` for logic
- `map(f)` always returns an array — it is `[.[] | f]`
- `to_entries` key is a string for objects, number for arrays
- Recursive `..` can be slow on large documents
- `jq_validate` in mcp-jq uses JS `JSON.parse`, not jq — may accept inputs jq would reject

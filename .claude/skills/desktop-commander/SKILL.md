---
name: desktop-commander
description: Desktop Commander MCP server for terminal sessions, filesystem ops, process management, file search, and surgical text editing — use when the user asks to run shell commands, manage processes, read/write files (including Excel/PDF), search file content, or edit files with search-replace blocks.
---

# Desktop Commander MCP Server — 21 Tools Reference

Configured in `.mcp.json` as `"desktop-commander"` (stdio, `npx @wonderwhy-er/desktop-commander@latest`). No authentication required. No environment variables needed.

> **MCP_DOCKER priority**: The global Claude Code settings prioritize `mcp__MCP_DOCKER__desktop-commander__*` over `mcp__desktop-commander__*`. The project-local server (`npx @wonderwhy-er/desktop-commander@latest`) is the fallback when MCP_DOCKER is unavailable.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| View server config | `get_config` | — |
| Change a config key | `set_config_value` | `key`, `value` |
| Start a shell/program | `start_process` | `command` |
| Send input to process | `interact_with_process` | `pid`, `input` |
| Read buffered output | `read_process_output` | `pid`, `offset`, `length` |
| Kill terminal session | `force_terminate` | `pid` |
| List active sessions | `list_sessions` | — |
| List all OS processes | `list_processes` | — |
| Terminate OS process | `kill_process` | `pid` |
| Read file/URL | `read_file` | `path`, `offset`, `length`, `isUrl` |
| Read several files | `read_multiple_files` | `paths` |
| Write or append file | `write_file` | `path`, `content`, `mode` |
| Create/write PDF | `write_pdf` | `path`, `content`, `operation` |
| Create directory | `create_directory` | `path` |
| List directory tree | `list_directory` | `path`, `depth` |
| Move or rename file | `move_file` | `source`, `destination` |
| Search by name/content | `start_search` | `path`, `pattern`, `type` |
| Get paginated search results | `get_more_search_results` | `searchId`, `offset` |
| Stop active search | `stop_search` | `searchId` |
| List active searches | `list_searches` | — |
| File metadata | `get_file_info` | `path` |
| Surgical search-replace | `edit_block` | `blockContent`, `expected_replacements` |
| Usage statistics | `get_usage_stats` | — |
| Recent tool call history | `get_recent_tool_calls` | `limit` |
| Open feedback form | `give_feedback_to_desktop_commander` | — |

## Common Workflows

### 1. Run a Shell Command and Capture Output
```
start_process(command="ls -la /workspace")
  → returns pid

read_process_output(pid=1234)
  → buffered stdout/stderr
```

### 2. Interactive Session (SSH / REPL / Dev Server)
```
# Start an SSH session
start_process(command="ssh user@host -p 2222")
  → pid=1234 (auto-detects ready state)

# Send commands
interact_with_process(pid=1234, input="nvidia-smi\n")

# Paginate output — avoid context overflow on large output
read_process_output(pid=1234, offset=0, length=200)
read_process_output(pid=1234, offset=200, length=200)

# Terminate session when done
force_terminate(pid=1234)
```

### 3. Read a File or URL
```
# Read a local file with line limits
read_file(path="/workspace/train.py", offset=0, length=100)

# Read a remote URL (30-second timeout; images rendered visually)
read_file(path="https://example.com/data.json", isUrl=True)

# Read Excel — returns structured data
read_file(path="/data/results.xlsx")
```

### 4. Write a File
```
# Overwrite entire file
write_file(path="/workspace/config.yaml", content="key: value\n", mode="rewrite")

# Append to log
write_file(path="/workspace/run.log", content="epoch 10 done\n", mode="append")

# Write Excel (JSON 2D array as content)
write_file(
    path="/data/output.xlsx",
    content='[["Name","Score"],["Alice",95],["Bob",88]]',
    mode="rewrite"
)
```

### 5. Surgical File Edit with `edit_block`
```
edit_block(blockContent="""config.yaml
<<<<<<< SEARCH
learning_rate: 0.001
=======
learning_rate: 0.0005
>>>>>>> REPLACE""")
```
When exact match fails, fuzzy search finds the closest match and reports similarity percentage.

### 6. Search Across a Project
```
# Find files by name pattern
start_search(path="/workspace", pattern="*.json", type="name")
  → returns searchId

# Find files containing a string
start_search(path="/workspace", pattern="ckpt_name", type="content")
  → returns searchId

# Retrieve results
get_more_search_results(searchId="abc123", offset=0)
get_more_search_results(searchId="abc123", offset=20)   # next page

# Stop when done
stop_search(searchId="abc123")
```

### 7. Process Management
```
list_processes()                    # all OS processes with PID, CPU, memory
list_sessions()                     # active terminal sessions managed by this server
kill_process(pid=5678)              # terminate OS process by PID
force_terminate(pid=1234)           # terminate a desktop-commander session
```

### 8. Configure the Server
```
get_config()
# → { blockedCommands: [...], defaultShell: "zsh",
#     allowedDirectories: [...], fileReadLineLimit: 1000,
#     fileWriteLineLimit: 50, telemetryEnabled: false }

set_config_value(key="defaultShell", value="bash")
set_config_value(key="fileReadLineLimit", value=2000)
set_config_value(key="allowedDirectories", value=["/workspace", "/data"])
set_config_value(key="blockedCommands", value=["rm -rf /"])
```

### 9. Create PDF from Markdown
```
write_pdf(
    path="/output/report.pdf",
    content="# Report\n\nSummary of results...",
    operation="create"
)
```

## Configuration

| Config Key | Type | Default | Description |
|-----------|------|---------|-------------|
| `blockedCommands` | array | system defaults | Shell commands always refused |
| `defaultShell` | string | system default | Shell for `start_process` (e.g. `"zsh"`, `"bash"`) |
| `allowedDirectories` | array | unrestricted | Filesystem tool access scope (does NOT affect terminal) |
| `fileReadLineLimit` | int | 1000 | Max lines returned by `read_file` per call |
| `fileWriteLineLimit` | int | 50 | Max lines written by `write_file` per call |
| `telemetryEnabled` | bool | true | Usage telemetry sent to server developer |

No API keys or `.env` vars required — the server runs locally via npx with no external auth.

## Known Behaviors

1. **`read_file` supports URLs** — set `isUrl: true`; 30-second timeout applies. Images are displayed visually (not as text). Excel files (`.xlsx`/`.xls`/`.xlsm`) return structured data; PDFs are extracted as text.
2. **`edit_block` fuzzy fallback** — when exact match fails, the tool finds the closest match and reports similarity %; all fuzzy operations are logged. Prefer exact content to avoid unintended edits.
3. **Interactive sessions via `start_process` + `interact_with_process`** — enables SSH, REPLs, dev servers, and long-running commands. Use `read_process_output` with `offset`/`length` to paginate buffered output and avoid context overflow.
4. **`allowedDirectories` restricts filesystem tools only** — `start_process` and other terminal tools can still access paths outside `allowedDirectories`; the restriction applies only to `read_file`, `write_file`, `list_directory`, etc.
5. **Auto-updates on every restart** — installed via `npx`, so the latest published version is pulled each time Claude Code restarts; no manual update step needed.
6. **`write_file` for Excel requires JSON 2D array** — pass a JSON string where each inner array is a row (e.g. `[["Header1","Header2"],["val1","val2"]]`). Use `write_pdf` for PDF output, which takes markdown as input.
7. **`list_directory` defaults to `depth=2`** — increase for deeper trees, but be cautious on large repos as output can be very large.

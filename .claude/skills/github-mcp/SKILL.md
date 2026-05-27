---
name: github-mcp
description: GitHub's official MCP server for repository management, issues, pull requests, GitHub Actions CI/CD, code security scanning, Dependabot, discussions, gists, notifications, projects, and more. Use when the user asks about GitHub repos, issues, PRs, Actions workflows, code scanning, Dependabot alerts, or any GitHub platform operations.
---

# GitHub MCP Server — Tool Reference

Official server from `ghcr.io/github/github-mcp-server`. Configured in `.mcp.json` as `"github"` (Docker stdio). Requires `GITHUB_PERSONAL_ACCESS_TOKEN` in `.env`, loaded automatically at session start.

## Toolsets

Enable via `GITHUB_TOOLSETS` env var. Default toolsets: `context, repos, issues, pull_requests, users`.

| Toolset | Description |
|---------|-------------|
| `context` | Current user info, teams — **strongly recommended** |
| `repos` | Repository read/write, file contents, branches, commits |
| `issues` | Issues CRUD, comments, labels, sub-issues |
| `pull_requests` | PR CRUD, reviews, comments, merging |
| `users` | User profiles and info |
| `actions` | GitHub Actions workflows, runs, jobs, logs, artifacts |
| `code_security` | Code scanning alerts (CodeQL, etc.) |
| `dependabot` | Dependabot vulnerability alerts |
| `discussions` | GitHub Discussions CRUD and comments |
| `gists` | Gist create/read/update/list |
| `git` | Low-level Git tree operations |
| `labels` | Label management |
| `notifications` | GitHub notification management |
| `orgs` | Organization tools |
| `projects` | GitHub Projects (v2) |
| `secret_protection` | Secret scanning alerts |
| `security_advisories` | Security advisories |
| `stargazers` | Stargazer listing |

## Quick Tool Map

### Context & Users
| Goal | Tool |
|------|------|
| Get current authenticated user | `get_me` |
| Get user's teams | `get_teams` |
| Get team members | `get_team_members` |

### Repositories (`repos` toolset)
| Goal | Tool | Key Params |
|------|------|-----------|
| Search repos | `search_repositories` | `query` |
| Get repo details | `get_repository` | `owner`, `repo` |
| Get file contents | `get_file_contents` | `owner`, `repo`, `path`, `ref` |
| Create/update file | `create_or_update_file` | `owner`, `repo`, `path`, `content`, `message` |
| List branches | `list_branches` | `owner`, `repo` |
| Create branch | `create_branch` | `owner`, `repo`, `branch`, `from_branch` |
| List commits | `list_commits` | `owner`, `repo`, `sha`, `per_page` |
| Get commit | `get_commit` | `owner`, `repo`, `sha` |
| Fork repo | `fork_repository` | `owner`, `repo` |
| Create repo | `create_repository` | `name`, `description`, `private` |
| Push files | `push_files` | `owner`, `repo`, `branch`, `files`, `message` |
| Get repo tree | `get_repository_tree` | `owner`, `repo`, `tree_sha`, `recursive` |

### Issues (`issues` toolset)
| Goal | Tool | Key Params |
|------|------|-----------|
| List issues | `list_issues` | `owner`, `repo`, `state`, `labels` |
| Get issue | `issue_read` (method: `get`) | `owner`, `repo`, `issue_number` |
| Get comments | `issue_read` (method: `get_comments`) | `owner`, `repo`, `issue_number` |
| Create/update issue | `issue_write` | `owner`, `repo`, `title`, `body`, `state` |
| Add comment | `add_issue_comment` | `owner`, `repo`, `issue_number`, `body` |
| Search issues | `search_issues` | `query` |

### Pull Requests (`pull_requests` toolset)
| Goal | Tool | Key Params |
|------|------|-----------|
| List PRs | `list_pull_requests` | `owner`, `repo`, `state` |
| Search PRs | `search_pull_requests` | `query` |
| Get PR / diff / reviews / comments | `pull_request_read` | `owner`, `repo`, `pullNumber`, `method` |
| Create PR | `create_pull_request` | `owner`, `repo`, `title`, `body`, `head`, `base` |
| Update PR | `update_pull_request` | `owner`, `repo`, `pullNumber`, `title`, `body`, `state` |
| Update PR branch | `update_pull_request_branch` | `owner`, `repo`, `pullNumber` |
| Merge PR | `merge_pull_request` | `owner`, `repo`, `pullNumber`, `merge_method` |
| Create/submit review | `pull_request_review_write` | `owner`, `repo`, `pullNumber`, `event`, `body` |
| Add comment to pending review | `add_comment_to_pending_review` | `owner`, `repo`, `pullNumber`, `body`, `path`, `line` |
| Reply to PR comment | `add_reply_to_pull_request_comment` | `owner`, `repo`, `pullNumber`, `comment_id`, `body` |
| Request Copilot review | `request_copilot_review` | `owner`, `repo`, `pullNumber` |

### GitHub Actions (`actions` toolset)
| Goal | Tool | Key Params |
|------|------|-----------|
| List workflows | `actions_list` (method: `list_workflows`) | `owner`, `repo` |
| List runs | `actions_list` (method: `list_workflow_runs`) | `owner`, `repo`, `resource_id` |
| Get run | `actions_get` (method: `get_workflow_run`) | `owner`, `repo`, `resource_id` |
| Get job logs | `get_job_logs` | `owner`, `repo`, `job_id` |
| Get failed logs | `get_job_logs` | `owner`, `repo`, `run_id`, `failed_only: true` |
| Trigger workflow | `actions_run_trigger` (method: `run_workflow`) | `owner`, `repo`, `workflow_id`, `ref` |
| Re-run workflow | `actions_run_trigger` (method: `rerun_workflow_run`) | `owner`, `repo`, `run_id` |
| Cancel run | `actions_run_trigger` (method: `cancel_workflow_run`) | `owner`, `repo`, `run_id` |

### Security
| Goal | Tool | Key Params |
|------|------|-----------|
| List code scanning alerts | `list_code_scanning_alerts` | `owner`, `repo`, `state`, `severity` |
| Get code scanning alert | `get_code_scanning_alert` | `owner`, `repo`, `alertNumber` |
| List Dependabot alerts | `list_dependabot_alerts` | `owner`, `repo`, `state`, `severity` |
| Get Dependabot alert | `get_dependabot_alert` | `owner`, `repo`, `alertNumber` |

### Discussions (`discussions` toolset)
| Goal | Tool |
|------|------|
| List discussions | `list_discussions` |
| Get discussion | `get_discussion` |
| Get comments | `get_discussion_comments` |
| Add comment | `discussion_comment_write` (method: `add`) |

### Gists (`gists` toolset)
| Goal | Tool |
|------|------|
| List gists | `list_gists` |
| Get gist | `get_gist` |
| Create gist | `create_gist` |
| Update gist | `update_gist` |

## Common Workflows

### 1. Investigate a Failed CI Run
```
get_me()  → confirm auth context
actions_list(method="list_workflow_runs", owner=X, repo=Y, resource_id="ci.yml")
  → find failed run_id
get_job_logs(owner=X, repo=Y, run_id=ID, failed_only=true)
  → read error output, diagnose
```

### 2. Triage Open Issues
```
list_issues(owner=X, repo=Y, state="open", labels="bug", per_page=20)
  → pick issue_number
issue_read(method="get", owner=X, repo=Y, issue_number=N)
issue_read(method="get_comments", owner=X, repo=Y, issue_number=N)
  → understand context, then issue_write to update or add_issue_comment
```

### 3. Create a PR from Changes
```
create_branch(owner=X, repo=Y, branch="feature/xyz", from_branch="main")
push_files(owner=X, repo=Y, branch="feature/xyz", files=[...], message="...")
create_pull_request(owner=X, repo=Y, title="...", body="...", head="feature/xyz", base="main")
```

### 4. Review Open PRs
```
list_pull_requests(owner=X, repo=Y, state="open")
get_pull_request_diff(owner=X, repo=Y, pullNumber=N)
get_pull_request_reviews(owner=X, repo=Y, pullNumber=N)
create_pull_request_review(owner=X, repo=Y, pullNumber=N, event="COMMENT", body="...")
```

### 5. Audit Security Alerts
```
list_code_scanning_alerts(owner=X, repo=Y, state="open", severity="high")
list_dependabot_alerts(owner=X, repo=Y, state="open", severity="critical")
```

### 6. Explore a Repo's File Structure
```
get_repository_tree(owner=X, repo=Y, recursive=true, path_filter="src/")
get_file_contents(owner=X, repo=Y, path="src/main.py", ref="main")
```

## Configuration

```
GITHUB_PERSONAL_ACCESS_TOKEN  — GitHub PAT (github.com/settings/tokens)
GITHUB_TOOLSETS               — Comma-separated toolsets (default: context,repos,issues,pull_requests,users)
                                Use "all" to enable everything
GITHUB_READ_ONLY              — Set to "1" to disable all write tools
GITHUB_HOST                   — For GitHub Enterprise (e.g. https://github.mycompany.com)
```

Token is loaded automatically at session start via `.env` / `SessionStart` hook.

## Required PAT Scopes (by toolset)

| Toolset | Scopes Needed |
|---------|--------------|
| repos, issues, pull_requests, actions | `repo` |
| code_security, dependabot | `security_events` or `repo` |
| orgs, context (teams) | `read:org` |
| gists | `gist` |
| notifications | `notifications` |

## Known Behaviors

1. **Default toolsets** (`context, repos, issues, pull_requests, users`) load automatically when `GITHUB_TOOLSETS` is not set — sufficient for most tasks.
2. **`get_job_logs` with `failed_only=true`** requires `run_id`, not `job_id` — returns logs for all failed jobs in that run.
3. **`issue_write`** handles both create (no `issue_number`) and update (with `issue_number`) in one tool.
4. **`push_files`** is preferred over `create_or_update_file` for multi-file commits — atomic single commit.
5. **Read-only mode** (`GITHUB_READ_ONLY=1`) silently skips write tools even if explicitly requested.
6. **Dynamic toolset discovery** (`GITHUB_DYNAMIC_TOOLSETS=1`) lets the model enable toolsets at runtime — useful when starting with a minimal set.
7. **`get_pull_request_diff`** returns raw unified diff — efficient for code review without loading full file contents.
8. **Actions `resource_id`** semantics vary by method: workflow ID/filename for runs, run ID for jobs — check method docs carefully.

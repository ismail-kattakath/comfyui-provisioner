---
name: dockerhub-mcp
description: Docker Hub MCP server for searching Docker images, managing repositories and tags, inspecting hardened images, and exploring Docker Hub namespaces. Use when the user asks about Docker images, Docker Hub repositories, container tags, Docker namespaces, or wants to search/manage Docker Hub content.
---

# Docker Hub MCP Server — Tool Reference

Built from `docker/hub-mcp` and installed at `~/.mcp-servers/hub-mcp`. Configured in `.mcp.json` as `"dockerhub"` (Node.js stdio via `bash -c` for portable `$HOME` expansion). Requires `HUB_PAT_TOKEN` in `.env` for authenticated access (private repos, write operations). Public search works without auth.

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| Search images/repos | `search` | `query`, `type`, `sort`, `order`, `from`, `size` |
| List namespaces | `get_namespaces` | `page`, `page_size` |
| List repos in namespace | `list_repositories_by_namespace` | `namespace`, `name`, `ordering`, `page`, `page_size` |
| Get repo details | `get_repository_info` | `namespace`, `repository` |
| Check repo exists | `check_repository` | `namespace`, `repository` |
| Create repo | `create_repository` | `namespace`, `body` |
| Update repo | `update_repository_info` | `namespace`, `repository`, `body` |
| List tags | `list_repository_tags` | `namespace`, `repository`, `architecture`, `os`, `page`, `page_size` |
| Get tag details | `read_repository_tag` | `namespace`, `repository`, `tag` |
| Check tag exists | `check_repository_tag` | `namespace`, `repository`, `tag` |
| Docker Hardened Images | `docker_hardened_images` | `namespace` |

## Search Query (`search`)

The `search` tool queries all Docker Hub content. Key params:

| Param | Description | Example |
|-------|-------------|---------|
| `query` | Search text | `"pytorch cuda"` |
| `type` | `"image"` or `"plugin"` | `"image"` |
| `sort` | `"pulls"`, `"updated_at"`, `"name"` | `"pulls"` |
| `order` | `"asc"` or `"desc"` | `"desc"` |
| `architectures` | Filter by arch | `["amd64", "arm64"]` |
| `operating_systems` | Filter by OS | `["linux"]` |
| `categories` | Filter by category | `["machine-learning"]` |
| `badges` | Filter by badge | `["official", "verified_publisher"]` |
| `from` | Pagination offset | `0` |
| `size` | Results per page | `25` |

## Common Workflows

### 1. Find the Best Base Image

```
search(query="pytorch cuda 12", type="image", sort="pulls", order="desc", size=10)
  → read pull counts, last updated, publisher badge
  → pick namespace/repository
get_repository_info(namespace="pytorch", repository="pytorch")
  → read description, categories, pull count, star count
list_repository_tags(namespace="pytorch", repository="pytorch", page_size=20)
  → find the right CUDA/Python version tag
read_repository_tag(namespace="pytorch", repository="pytorch", tag="2.3.0-cuda12.1-cudnn8-runtime")
  → get digest, image size, architecture support
```

### 2. Explore Your Own Repositories

```
get_namespaces()
  → get list of orgs/personal namespace
list_repositories_by_namespace(namespace="myorg", ordering="last_updated", page_size=25)
  → see all repos, last push time, pull count
get_repository_info(namespace="myorg", repository="myapp")
  → full details: visibility, description, tags count
```

### 3. Audit Tags in a Repository

```
list_repository_tags(namespace="nvidia", repository="cuda", architecture="amd64", os="linux", page_size=50)
  → see all available tags filtered by arch/OS
read_repository_tag(namespace="nvidia", repository="cuda", tag="12.3.0-runtime-ubuntu22.04")
  → get digest, compressed size, last pushed, image layers
check_repository_tag(namespace="nvidia", repository="cuda", tag="12.4.0-base-ubuntu24.04")
  → confirm tag exists before pinning in Dockerfile
```

### 4. Manage a Repository

```
# Create new repo (requires HUB_PAT_TOKEN)
create_repository(namespace="myorg", body={
  "name": "my-new-repo",
  "description": "My new container image",
  "is_private": false
})

# Update description/visibility
update_repository_info(namespace="myorg", repository="my-new-repo", body={
  "description": "Updated description",
  "full_description": "# Full README content here"
})
```

### 5. Check Docker Hardened Images

```
docker_hardened_images()
  → list all available Docker Hardened Images (security-hardened mirrors)
docker_hardened_images(namespace="docker")
  → narrow to a specific namespace
```

## Configuration

```
HUB_PAT_TOKEN    — Docker Hub Personal Access Token
                   (hub.docker.com → Account Settings → Personal Access Tokens)
                   Required for: private repos, create/update operations, namespace listing
                   Optional for: public search, public repo/tag reads

HUB_USERNAME     — Docker Hub username (optional, used with PAT for some operations)
```

Both loaded automatically at session start via `.env` / `SessionStart` hook.

The server is installed at `~/.mcp-servers/hub-mcp` — requires Node.js 22+. To update:
```bash
cd ~/.mcp-servers/hub-mcp && git pull && npm install && npm run build
```

## Known Behaviors

1. **Public search works without auth** — `search`, `get_repository_info`, `list_repository_tags`, and `read_repository_tag` all work unauthenticated for public content.
2. **`get_namespaces` requires auth** — returns your personal namespace + org memberships; needs `HUB_PAT_TOKEN`.
3. **`create_repository` / `update_repository_info` require auth** — write operations always need a PAT with write scope.
4. **`docker_hardened_images`** — returns Docker's security-hardened image mirrors, not the same as regular Docker Official Images; useful when security compliance matters.
5. **Pagination** — `list_repositories_by_namespace` and `list_repository_tags` are paginated; use `page` + `page_size` (default page_size varies by tool).
6. **`search` `from`/`size`** — uses offset-based pagination: `from=0, size=25` → first page; `from=25, size=25` → second page.
7. **Tag digest** — `read_repository_tag` returns the content-addressable digest (`sha256:...`) for reproducible pulls with `docker pull image@sha256:...`.
8. **`ordering` on `list_repositories_by_namespace`** — use `"last_updated"` for most recently pushed, `"-pull_count"` (minus prefix for desc) for most pulled.

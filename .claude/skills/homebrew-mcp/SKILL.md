---
name: homebrew-mcp
description: Manage Homebrew packages, casks, taps, and background services on macOS via the homebrew-mcp MCP server (mcp__homebrew__*). Use for installing/uninstalling software, upgrading packages, managing background services (start/stop/restart), running diagnostics, and adding taps. macOS only.
---

# Homebrew MCP

MCP server: `homebrew` (`uvx homebrew-mcp`) — 19 tools.

## Tool Reference

### Search & Info
| Tool | Use |
|------|-----|
| `mcp__homebrew__search` | Search formulae or casks |
| `mcp__homebrew__info` | Detailed info about a package |
| `mcp__homebrew__list_installed` | List all installed formulae or casks |
| `mcp__homebrew__list_outdated` | Packages with newer versions available |
| `mcp__homebrew__deps` | Dependency tree for a package |

### Package Management
| Tool | Use |
|------|-----|
| `mcp__homebrew__install` | Install a formula or cask (`cask=True` for GUI apps) |
| `mcp__homebrew__uninstall` | Uninstall a formula or cask |
| `mcp__homebrew__upgrade` | Upgrade a specific package |
| `mcp__homebrew__upgrade_all` | Upgrade all installed packages |
| `mcp__homebrew__cleanup` | Remove old versions and stale downloads |

### Services (background daemons)
| Tool | Use |
|------|-----|
| `mcp__homebrew__list_services` | List all managed services and their status |
| `mcp__homebrew__start_service` | Start a background service |
| `mcp__homebrew__stop_service` | Stop a background service |
| `mcp__homebrew__restart_service` | Restart a background service |

### Taps
| Tool | Use |
|------|-----|
| `mcp__homebrew__tap` | Add a third-party repo (`user/repo`) |
| `mcp__homebrew__untap` | Remove a third-party repo |
| `mcp__homebrew__list_taps` | List all tapped repositories |

### System
| Tool | Use |
|------|-----|
| `mcp__homebrew__doctor` | Run Homebrew diagnostics |
| `mcp__homebrew__update` | Update Homebrew and formula definitions |

## Common Patterns

```
Install Ollama:              install("ollama")
Start Ollama as service:     start_service("ollama")
Stop Ollama service:         stop_service("ollama")
Restart Ollama service:      restart_service("ollama")
Check service status:        list_services()
Install a GUI app (cask):    install("docker", cask=True)
Run health check:            doctor()
```

## Notes
- Services wrap `brew services` (launchd on macOS) — no sudo needed for user-level services.
- `install` with `cask=True` installs from `homebrew/cask`; omit for CLI formulae.
- Run `update()` before `upgrade_all()` to refresh formula definitions.

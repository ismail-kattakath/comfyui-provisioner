---
name: ollama-mcp
description: Manage and use local Ollama models via the ollama-mcp MCP server (mcp__ollama__*). Use for pulling/deleting/listing models, running chat or text generation, generating embeddings, and checking running models. Ollama must be running locally (default: http://127.0.0.1:11434).
---

# Ollama MCP

MCP server: `ollama` (`npx -y ollama-mcp`) — 14 tools covering the full Ollama SDK.
Env: `OLLAMA_HOST=http://127.0.0.1:11434` (configured in `.mcp.json`).

## Tool Reference

### Model Management
| Tool | Use |
|------|-----|
| `mcp__ollama__ollama_list` | List all locally available models |
| `mcp__ollama__ollama_show` | Detailed info about a specific model |
| `mcp__ollama__ollama_pull` | Download a model from Ollama library |
| `mcp__ollama__ollama_delete` | Remove a model from local storage |
| `mcp__ollama__ollama_copy` | Copy/alias an existing model |
| `mcp__ollama__ollama_push` | Push a model to Ollama library |
| `mcp__ollama__ollama_create` | Create a custom model from a Modelfile |

### Runtime
| Tool | Use |
|------|-----|
| `mcp__ollama__ollama_ps` | List currently loaded/running models |
| `mcp__ollama__ollama_chat` | Chat with a model (multi-turn, supports tool calling) |
| `mcp__ollama__ollama_generate` | Single-turn text completion |
| `mcp__ollama__ollama_embed` | Generate embeddings for text |

### Cloud (requires `OLLAMA_API_KEY`)
| Tool | Use |
|------|-----|
| `mcp__ollama__ollama_web_search` | Web search via Ollama Cloud |
| `mcp__ollama__ollama_web_fetch` | Fetch and parse a web page via Ollama Cloud |

## Common Patterns

### Check what's installed and running
```
ollama_list()          → all local models
ollama_ps()            → currently loaded models (VRAM usage)
ollama_show("llama3.2") → architecture, parameters, quantization
```

### Pull and remove models
```
ollama_pull("llama3.2")           → latest tag
ollama_pull("qwen2.5-coder:7b")   → specific tag
ollama_delete("mistral:latest")   → free up disk
```

### Chat and generate
```
ollama_chat(model="llama3.2", messages=[{"role":"user","content":"..."}])
ollama_generate(model="llama3.2", prompt="...")
```

### Embeddings
```
ollama_embed(model="nomic-embed-text", input=["text1", "text2"])
```

## Prerequisites
- Ollama must be installed and running: `brew install ollama` + `brew services start ollama`
- Use `mcp__homebrew__start_service("ollama")` to ensure the service is up before calling any ollama tool.

## Notes
- `ollama_chat` supports multi-turn history and function/tool calling for models that support it.
- GPU utilisation is visible via `ollama_ps` — shows CPU/GPU split per loaded model.
- Large models (70B+) require significant VRAM; check `ollama_show` for parameter count before pulling.
- The Ollama Skill in SkillsForge (`rawveg/skillsforge-marketplace` → `ollama`) provides API recipes and prompting best practices as a companion to this MCP server.

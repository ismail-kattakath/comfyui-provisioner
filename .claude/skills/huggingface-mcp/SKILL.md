---
name: huggingface-mcp
description: Official Hugging Face MCP server for searching models, datasets, Spaces, papers, and HF docs, running jobs on HF infrastructure, and dynamically calling community Gradio Space tools. Use when the user asks about Hugging Face models, datasets, Spaces, ML papers, HF documentation, or wants to run inference/jobs on Hugging Face infrastructure.
---

# Hugging Face MCP Server — Tool Reference

The server connects directly to the Hugging Face Hub via SSE at `https://huggingface.co/mcp`. Configured in `.mcp.json` as `"huggingface"`. Requires `HF_TOKEN` in `.env` for authenticated access (higher rate limits, private repos).

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| Find AI apps / Spaces | `spaces_semantic_search` | `query` |
| Find ML papers | `papers_semantic_search` | `query` |
| Search models | `model_search` | `query`, `task`, `library`, `sort` |
| Search datasets | `dataset_search` | `query`, `author`, `tags` |
| Search HF docs | `documentation_semantic_search` | `query` |
| Model/dataset/Space details | `hub_repository_details` | `repo_id`, `repo_type` |
| Run/monitor jobs | `run_and_manage_jobs` | `command`, `hardware` |

## Common Recipes

### Find the best model for a task
```
model_search(query="image segmentation", task="image-segmentation", sort="downloads", limit=5)
```

### Find a quantized/GGUF model
```
model_search(query="Llama 3 GGUF Q4", library="gguf", sort="downloads", limit=5)
```

### Find LTXV or video generation models
```
model_search(query="LTXV video generation", task="text-to-video", sort="downloads", limit=5)
```

### Find a Space that does a specific thing
```
spaces_semantic_search(query="audio transcription whisper")
spaces_semantic_search(query="image upscaling real-esrgan")
```

### Search ML papers by topic
```
papers_semantic_search(query="vision language models grounding")
papers_semantic_search(query="video diffusion latent")
```

### Look up a specific model's details, files, and README
```
hub_repository_details(repo_id="black-forest-labs/FLUX.1-dev", repo_type="model")
hub_repository_details(repo_id="Lightricks/LTX-Video", repo_type="model")
```

### Find ComfyUI-compatible datasets
```
dataset_search(query="ComfyUI workflows", tags=["comfyui"])
dataset_search(query="video generation prompts")
```

### Answer HF library questions (transformers, diffusers, PEFT, etc.)
```
documentation_semantic_search(query="how to use LoRA adapters with PEFT")
documentation_semantic_search(query="diffusers pipeline text to video")
documentation_semantic_search(query="transformers Trainer options")
```

### Run a job on HF infrastructure
```
run_and_manage_jobs(command="python train.py", hardware="t4-medium")
```

## Workflows

### 1. Find the Best Model for a Use Case

```
model_search(query="<task description>", task="<task>", sort="downloads", limit=10)
  -> pick repo_id from results
hub_repository_details(repo_id="<org/model>", repo_type="model")
  -> read model card, tags, supported libraries, file list
```

### 2. Explore a Research Topic

```
papers_semantic_search(query="<topic>", limit=10)
  -> read paper titles, abstracts, arxiv links
model_search(query="<topic>", sort="trending", limit=5)
  -> find implementations of the paper's methods
```

### 3. Find a Community Space Tool

```
spaces_semantic_search(query="<tool description>")
  -> get Space ID (e.g. "hf-audio/whisper-large-v3")
hub_repository_details(repo_id="<org/space>", repo_type="space")
  -> read Space README, understand inputs/outputs
```

### 4. Verify a Model Exists and Get Download Info

```
hub_repository_details(repo_id="<org/model>", repo_type="model")
  -> confirm existence, get file list (weights, configs, tokenizer)
  -> check license, tags, pipeline_tag
```

### 5. Answer a Diffusers / Transformers Question

```
documentation_semantic_search(query="<exact question>")
  -> returns relevant docs sections, API references, guides
```

## Dynamic Spaces (Experimental)

When Dynamic Spaces is enabled in HF MCP settings (`huggingface.co/settings/mcp`), the server can discover and call MCP-compatible Gradio Spaces at runtime without pre-registering them. This lets community tools (e.g. image generators, audio processors) be used directly as tools.

Gradio Spaces that expose MCP expose their functions as named tools with typed arguments — call them the same way as built-in tools.

## Enum / Filter Reference

### Model Tasks (`task`)
`text-generation`, `text-to-image`, `text-to-video`, `image-to-image`, `image-segmentation`, `object-detection`, `automatic-speech-recognition`, `text-classification`, `token-classification`, `question-answering`, `summarization`, `translation`, `feature-extraction`, `image-classification`, `depth-estimation`, `image-to-video`, `video-classification`

### Model Libraries (`library`)
`transformers`, `diffusers`, `peft`, `trl`, `gguf`, `llama-cpp`, `timm`, `sentence-transformers`, `speechbrain`, `pytorch`, `tensorflow`, `jax`, `onnx`

### Sort Options
- Models: `downloads`, `likes`, `trending`, `created_at`
- Datasets: `downloads`, `likes`, `trending`, `created_at`

### Hardware (Jobs)
`cpu-basic`, `cpu-upgrade`, `t4-small`, `t4-medium`, `a10g-small`, `a10g-large`, `a100-large`

### Repo Types
`model`, `dataset`, `space`

## Configuration

```
HF_TOKEN  — Hugging Face access token (huggingface.co/settings/tokens)
            Read access: search + public repos
            Write access: required for running jobs, private repos
```

Token is loaded automatically at session start via the `.env` / `SessionStart` hook.

## Known Behaviors

1. **Unauthenticated requests** work for public model/dataset/Space search but hit lower rate limits.
2. **`hub_repository_details`** returns metadata, file list, and links. README inclusion is a server-level toggle in `huggingface.co/settings/mcp`, not a per-call parameter.
3. **`model_search` without `task` filter** returns broader results; combine with `library` for precision.
4. **Papers endpoint** is semantic (embedding-based), not keyword — phrase queries naturally.
5. **Spaces search** returns live Spaces; some may be sleeping and need a warm-up call.
6. **Dynamic Spaces** require the feature to be toggled on in `huggingface.co/settings/mcp` — not enabled by default.
7. **Job runs** bill against your HF account compute quota.

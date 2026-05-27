---
name: ollama-vision
description: Analyze or describe any image using a vision-capable Ollama model. Accepts a local file path or a public URL. Returns natural language description. Use as the input stage for ltx-prompt-gen or any image-understanding task.
---

# Ollama Vision — Image Understanding

Uses `mcp__ollama__ollama_chat` with a vision-capable model to analyze images.
Images must be base64-encoded before passing to the `images` array.

**Prerequisites:** Ollama running with a vision model installed. See `ollama-service` skill.

## Vision-capable models (local)

| Model | Vision | NSFW-tolerant | Size |
|-------|--------|---------------|------|
| `qwen3.5:9b` | ✅ | ❌ (RLHF-aligned) | 5.8 GB |
| `gemma3-heretic:Q4_K_M` | ❌ GGUF strip | ✅ abliterated | 6.8 GB |

> `qwen3.5:9b` is the default vision model. For NSFW descriptions, use `ltx-prompt-gen`
> which chains vision description into a purpose-built foreword.

## Step 1 — Encode the image

### Local file
```bash
IMG_B64=$(base64 -i /path/to/image.jpg | tr -d '\n')
```

### Public URL
```bash
IMG_B64=$(curl -sL "https://example.com/photo.jpg" | base64 | tr -d '\n')
```

## Step 2 — Call via REST API (use for all images)

The `mcp__ollama__ollama_chat` MCP tool has parameter size limits (~200 KB encoded).
Always use the REST API directly for real images:

```python
import json, subprocess, base64

def describe_image(image: str, prompt: str = "Describe this image in detail.") -> str:
    if image.startswith("http"):
        img_bytes = subprocess.run(["curl", "-sL", image],
                                   capture_output=True, timeout=30).stdout
    else:
        img_bytes = open(image, "rb").read()
    img_b64 = base64.b64encode(img_bytes).decode()

    payload = {
        "model": "qwen3.5:9b",
        "messages": [{"role": "user", "content": prompt, "images": [img_b64]}],
        "stream": False
    }
    r = subprocess.run(
        ["curl", "-s", "-X", "POST", "http://localhost:11434/api/chat",
         "-H", "Content-Type: application/json", "-d", json.dumps(payload)],
        capture_output=True, text=True, timeout=120
    )
    return json.loads(r.stdout)["message"]["content"]
```

## Step 3 — Or call via MCP tool (images ≤ ~200 KB encoded only)

```python
mcp__ollama__ollama_chat(
    model="qwen3.5:9b",
    messages=[{
        "role": "user",
        "content": "Describe this image in detail.",
        "images": ["<BASE64_STRING>"]
    }]
)
```

## Bash one-liner (quick check)

```bash
IMG_B64=$(base64 -i /path/to/image.jpg | tr -d '\n') && \
python3 -c "
import json,subprocess
payload={'model':'qwen3.5:9b','messages':[{'role':'user','content':'Describe this image.','images':['$IMG_B64']}],'stream':False}
r=subprocess.run(['curl','-s','-X','POST','http://localhost:11434/api/chat','-H','Content-Type: application/json','-d',json.dumps(payload)],capture_output=True,text=True,timeout=120)
print(json.loads(r.stdout)['message']['content'])
"
```

## Notes

- The `images` field is a list — you can pass multiple images in one call.
- Ollama trims thinking tokens from the response by default; raw reasoning is not returned.
- For NSFW scene script generation from an image, use the `ltx-prompt-gen` skill instead —
  it bundles this vision call with the TenStrip foreword into a single pipeline.

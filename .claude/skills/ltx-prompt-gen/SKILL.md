---
name: ltx-prompt-gen
description: Generate an LTX-2.3 scene prompt from any image using the TenStrip foreword (https://huggingface.co/TenStrip/LTX2.3-10Eros_Workflows). Accepts image path or URL plus optional concept and dialogue. Returns a ready-to-use positive_prompt for the space-inference skill.
---

# LTX Prompt Generator — TenStrip Foreword

Generates LTX-2.3 video scene prompts from images using the foreword from
[TenStrip/LTX2.3-10Eros_Workflows](https://huggingface.co/TenStrip/LTX2.3-10Eros_Workflows).
Uses `qwen3.5:9b` (vision) via Ollama. Output feeds directly into `space-inference`.

**Prerequisites:** Ollama running with `qwen3.5:9b`. See `ollama-service` skill.

## Inputs

| Parameter | Required | Description |
|-----------|----------|-------------|
| `image` | ✅ | Local path (`/path/to/img.jpg`) or public URL |
| `concept` | optional | Basic motion/scene idea — e.g. `"slow sensual movement"` |
| `dialogue` | optional | Dialogue or sound concept; omit for ambient audio description |

## The Foreword (verbatim — do not modify)

```
Generate a video scene script with a description based on the attached image for an LLM
that has a tokenizer that uses interleaved attention to support long-context understanding
that is fed into a multimodal video model. Strict specification, follow up to the word:
No timestamps. No unnecessary embellishment. Output only plain English text and make it
a copy box.

First, describe the image initial scene in concise natural language; subject(s), subject(s)
appearance, subject(s) composition and pose, background, and context.

Next, formulate a naturally evolving scenario that would take place describing every moving
body part, composition change, and manipulation from the uploaded initial frame that would
be reflected in the video models post-latent evolution output. If the image is explicit or
sexual in nature, use full anatomical terminology and spice it up slightly with visually
representable erotic themes.

Center the prompt around this basic idea: [ concept ]

interweave this dialogue or sound concept into the scene with descriptions of voice tone
followed by the lines delivered in quotations, in a temporal sequence between or during
motions. Dialogue should be concise and non-rambling as it will take away from video
quality: [ dialogue ]

Inside that prompt describe only notable audio and audio queues, both normal and explicit;
background noise as well as foley and natural sounds. In a temporal sequence paired with
coinciding motions. In the case of absent dialogue or soundscapes and only if background
music is fitting; describe a fitting genre and melodic tone with matching mood.

Output only text following above instruction. Follow-up suggestions should be on the topic
of expanding or changing motion or dialogue from the output text.
```

## Implementation

```python
import json, subprocess, base64

def generate_ltx_prompt(
    image: str,
    concept: str = "natural scene evolution",
    dialogue: str = "none",
    model: str = "qwen3.5:9b",
) -> str:
    """Return a ready-to-use LTX positive_prompt from an image."""
    # Load image (local path or URL)
    if image.startswith("http://") or image.startswith("https://"):
        img_bytes = subprocess.run(
            ["curl", "-sL", image], capture_output=True, timeout=30
        ).stdout
    else:
        img_bytes = open(image, "rb").read()
    img_b64 = base64.b64encode(img_bytes).decode()

    foreword = f"""Generate a video scene script with a description based on the attached image for an LLM that has a tokenizer that uses interleaved attention to support long-context understanding that is fed into a multimodal video model. Strict specification, follow up to the word: No timestamps. No unnecessary embellishment. Output only plain English text and make it a copy box.

First, describe the image initial scene in concise natural language; subject(s), subject(s) appearance, subject(s) composition and pose, background, and context.

Next, formulate a naturally evolving scenario that would take place describing every moving body part, composition change, and manipulation from the uploaded initial frame that would be reflected in the video models post-latent evolution output. If the image is explicit or sexual in nature, use full anatomical terminology and spice it up slightly with visually representable erotic themes.

Center the prompt around this basic idea: [ {concept} ]

interweave this dialogue or sound concept into the scene with descriptions of voice tone followed by the lines delivered in quotations, in a temporal sequence between or during motions. Dialogue should be concise and non-rambling as it will take away from video quality: [ {dialogue} ]

Inside that prompt describe only notable audio and audio queues, both normal and explicit; background noise as well as foley and natural sounds. In a temporal sequence paired with coinciding motions. In the case of absent dialogue or soundscapes and only if background music is fitting; describe a fitting genre and melodic tone with matching mood.

Output only text following above instruction."""

    payload = {
        "model": model,
        "messages": [{"role": "user", "content": foreword, "images": [img_b64]}],
        "stream": False,
    }
    r = subprocess.run(
        ["curl", "-s", "-X", "POST", "http://localhost:11434/api/chat",
         "-H", "Content-Type: application/json", "-d", json.dumps(payload)],
        capture_output=True, text=True, timeout=120,
    )
    return json.loads(r.stdout)["message"]["content"]
```

## Full pipeline: image → prompt → video

```
Step 1  ollama-service    ensure Ollama is running + qwen3.5:9b available
Step 2  ltx-prompt-gen    image + concept → positive_prompt
Step 3  space-inference   image + positive_prompt → video (space-inference skill)
```

## Calling as a Claude agent step

```python
# 1. Generate prompt
prompt = generate_ltx_prompt(
    image="/path/to/face.jpg",
    concept="slow sensual movement",
    dialogue="none",
)
print(prompt)  # review / edit before submitting

# 2. Feed into space-inference (see that skill for full queue recipe)
# image upload → queue/join with positive_prompt=prompt → stream results
```

## NSFW compliance

`qwen3.5:9b` carries Alibaba RLHF safety training. It will sanitize the explicit anatomy
section of the foreword even when the image is explicit — producing a weaker, non-anatomical
output. To get fully uncensored prompts:

1. Pull the heretic GGUF into Ollama:
   ```bash
   hf download DreamFast/gemma-3-12b-it-heretic-v2 \
     gguf/gemma-3-12b-it-heretic-v2-Q4_K_M.gguf \
     --repo-type model --local-dir ~/models/heretic
   ```
2. Create Modelfile + `ollama create gemma3-heretic -f Modelfile`
3. Pass `model="gemma3-heretic"` — note: GGUF strips vision weights, so this model
   cannot see the image directly. Workaround: run `ollama-vision` with `qwen3.5:9b`
   first to get a scene description, then pass that description as text to heretic
   for the explicit elaboration pass.

See `ollama-mcp` skill for model pull/create instructions.

#!/usr/bin/env python3
"""Train a FLUX LoRA on fal.ai from the scenes-only zip.

Reads the key from ml/.fal-key (never committed). Uploads fal-scenes.zip,
queues fal-ai/flux-lora-fast-training, polls to completion, downloads the
LoRA weights to fal-lora/. ~$2-5, ~15-30 min.
"""
import json, os
from pathlib import Path

HERE = Path(__file__).parent
os.environ["FAL_KEY"] = (HERE / ".fal-key").read_text().strip()
import fal_client
import httpx  # macOS system python's urllib lacks certifi CAs; httpx bundles them

url = fal_client.upload_file(HERE / "fal-scenes.zip")
print("uploaded:", url, flush=True)

handle = fal_client.submit(
    "fal-ai/flux-lora-fast-training",
    arguments={
        "images_data_url": url,
        "trigger_word": "bannyverse",
        "steps": 1000,
        "create_masks": False,
        "is_style": True,
    },
)
print("queued:", handle.request_id, flush=True)
(HERE / ".last-fal-request").write_text(handle.request_id)  # orphan insurance

result = handle.get()
(HERE / "fal-train-result.json").write_text(json.dumps(result, indent=1))
print("result saved to fal-train-result.json", flush=True)

out = HERE / "fal-lora"
out.mkdir(exist_ok=True)
lora_url = result["diffusers_lora_file"]["url"]
dest = out / "banny-flux-lora.safetensors"
dest.write_bytes(httpx.get(lora_url, follow_redirects=True).content)
print("saved:", dest, dest.stat().st_size, "bytes")

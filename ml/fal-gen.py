#!/usr/bin/env python3
"""Generate a bannyverse backdrop via fal FLUX + our LoRA.

fal-gen.py <out.png> <prompt words> [WxH]   (default 1024x576)
~$0.03/image. Raw output; run banny-tool stylize for the house look.
"""
import json, os, sys
from pathlib import Path

HERE = Path(__file__).parent
os.environ["FAL_KEY"] = (HERE / ".fal-key").read_text().strip()
import fal_client
import httpx

out = Path(sys.argv[1])
text = sys.argv[2]
w, h = (int(v) for v in sys.argv[3].split("x")) if len(sys.argv) > 3 else (1024, 576)

lora_url = json.loads((HERE / "fal-train-result.json").read_text())[
    "diffusers_lora_file"]["url"]
result = fal_client.subscribe(
    "fal-ai/flux-lora",
    arguments={
        "prompt": f"bannyverse pixel art scene, {text}, flat colors",
        "image_size": {"width": w, "height": h},
        "num_inference_steps": 28,
        "guidance_scale": 3.5,
        "seed": 7,
        "loras": [{"path": lora_url, "scale": 1.0}],
        "enable_safety_checker": False,
    },
)
img_url = result["images"][0]["url"]
out.write_bytes(httpx.get(img_url, follow_redirects=True).content)
print("saved", out)

#!/usr/bin/env python3
"""Generate a native-pixel backdrop via Retro Diffusion.

rd-gen.py <out.png> <prompt words> [WxH] [--style S] [--palette img.png]

Defaults: 384x216 (16:9 native pixels), style rd_plus__environment.
--palette constrains output colors to the given image's palette (use a
reference scene from dataset/). Saves native PNG + <out>-4x.png upscale.
Key: ml/.rd-key from retrodiffusion.ai/app/devtools. ~$0.06/image.
"""
import base64, io, json, sys
from pathlib import Path
import httpx
from PIL import Image

HERE = Path(__file__).parent
args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {}
argv = sys.argv[1:]
for i, a in enumerate(argv):
    if a in ("--style", "--palette"):
        flags[a[2:]] = argv[i + 1]
        args.remove(argv[i + 1])

out = Path(args[0])
text = args[1]
w, h = (int(v) for v in args[2].split("x")) if len(args) > 2 else (384, 216)

payload = {
    "prompt": f"pixel art scene, {text}, flat colors, game backdrop",
    "width": w,
    "height": h,
    "num_images": 1,
    "prompt_style": flags.get("style", "rd_plus__environment"),
    "seed": 7,
}
if "palette" in flags:
    payload["input_palette"] = base64.b64encode(
        Path(flags["palette"]).read_bytes()).decode()

r = httpx.post(
    "https://api.retrodiffusion.ai/v1/inferences",
    headers={"X-RD-Token": (HERE / ".rd-key").read_text().strip()},
    json=payload, timeout=120)
r.raise_for_status()
data = r.json()
img = Image.open(io.BytesIO(base64.b64decode(data["base64_images"][0])))
img.save(out)
img.resize((img.width * 4, img.height * 4), Image.NEAREST).save(
    out.with_stem(out.stem + "-4x"))
print(f"saved {out} ({img.width}x{img.height}), "
      f"cost {data.get('balance_cost')}, remaining {data.get('remaining_balance')}")

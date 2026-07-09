#!/usr/bin/env python3
"""Generate a bannyverse backdrop: gen.py <out.png> <prompt words> [WxH]

Uses the trained LoRA (banny-lora.safetensors) with the validated recipe:
50 steps, grain/character negative prompt, then grid+palette normalize.
Writes both <out>-raw.png and <out>.png (normalized).
"""
import sys
from pathlib import Path
import torch
from diffusers import StableDiffusionPipeline
from PIL import Image

out = Path(sys.argv[1])
text = sys.argv[2]
w, h = (int(v) for v in sys.argv[3].split("x")) if len(sys.argv) > 3 else (768, 512)

NEG = ("noisy, grainy, dithered, blurry, photo, realistic, "
       "banana character, sprite, white background")

pipe = StableDiffusionPipeline.from_pretrained(
    "stable-diffusion-v1-5/stable-diffusion-v1-5",
    torch_dtype=torch.float16, safety_checker=None)
pipe.load_lora_weights(Path(__file__).parent / "banny-lora.safetensors")
pipe = pipe.to("mps")

img = pipe(f"bannyverse pixel art scene, {text}, flat colors",
           negative_prompt=NEG, num_inference_steps=50, width=w, height=h,
           generator=torch.Generator("mps").manual_seed(7)).images[0]
img.save(out.with_stem(out.stem + "-raw"))
# normalize: box-downscale to 1/4 grid, 16-color palette snap, nearest upscale
# (quick stand-in for PixelStyler; the app pipeline uses PixelStyler proper)
g = img.resize((w // 4, h // 4), Image.BOX).quantize(
    colors=16, method=Image.MEDIANCUT, dither=Image.Dither.NONE)
g.convert("RGB").resize((w, h), Image.NEAREST).save(out)
print("saved", out)

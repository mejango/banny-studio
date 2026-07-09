# Banny style-model pipeline (generative SVG backdrops)

Goal: prompt → house-style pixel scene → normalized grid/palette → SVG.

## Dataset (this dir)
- `dataset/scene-*.png|txt` — 512px first frames of the reference GIF
  backdrops with captions. Trigger phrase: "bannyverse pixel art scene".
- TODO next: render the 124 catalog SVGs (App/Resources/BannyAssets/svg,
  400x400 pixel-grid paths) to PNG and add as `part-*` pairs — needs an
  SVG rasterizer pass (the app's own renderer or resvg).

## Steps
1. LoRA fine-tune a small SD checkpoint on `dataset/` (MLX:
   `mlx_lora` / diffusers kohya scripts; rank 16, ~2-3k steps).
2. Inference in-app: prompt → 512px gen → PixelStyler normalize
   (grid ~240, palette from the dataset) → SVG emit (run-length rects,
   parser/emitter to be built in tools/) → bank asset or sparkle loop.
3. Keep everything deterministic after the sampler (seeded).

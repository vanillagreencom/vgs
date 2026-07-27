# Wallpaper upscaling

Local, one-shot AI super-resolution for theme wallpapers, via `bin/vshell-upscale`.

## Why / design constraints

Theme wallpapers should ship at 6K+. Source art is often ~2.5K, so we upscale.
The tool is deliberately **one-shot**: each invocation loads a model, processes
one image, and the process **exits** — the model and its VRAM are released
immediately. There is **no daemon and nothing stays resident when idle**. This
is the reason we do NOT use ComfyUI/chaiNNer/SUPIR-style servers (they keep
models loaded in VRAM between jobs) even though a diffusion model can look
flashier: for our mixed photo + flat/geometric wallpapers, diffusion SR also
*hallucinates* texture and warps clean gradients/edges, and needs a 24GB GPU.
See the research summary at the bottom.

Engine: `realesrgan-ncnn-vulkan` (Vulkan, no Python/torch, GPU or CPU), driven
with better-than-stock ncnn weights.

## Setup (once)

```bash
vshell-upscale setup
```

Downloads the binary + models into a cache dir — **never into the repo**:

- default `~/.local/share/vshell/upscale/` (override with `$VSHELL_UPSCALE_HOME`)
- `realesrgan-ncnn-vulkan` + base models from the Real-ESRGAN v0.2.5.0 release
- better ncnn weights (best-effort) from the Upscayl model set:
  `ultrasharp-4x`, `digital-art-4x`, `remacri-4x`, `high-fidelity-4x`

`vshell-upscale` auto-runs setup on first use if the cache is missing. Clearing
the cache dir fully uninstalls it.

## Usage

```bash
# single image (auto -> photo model), 4x then Lanczos-downscale to 6016px wide
vshell-upscale in.jpg out.jpg

# flat / geometric / illustration art -> digital-art model (crisp edges, no
# invented texture). Use this for Bauhaus-style, aurora, and vector wallpapers.
vshell-upscale in.png out.jpg --type art

# photographs -> ultrasharp (falls back to realesrgan-x4plus if not installed)
vshell-upscale in.jpg out.jpg --type photo

# batch a folder
vshell-upscale --dir ./src ./out --type art

vshell-upscale models          # list installed models
vshell-upscale --help
```

Options: `--type photo|art|auto` (default auto→photo), `--width N` (post-4x
downscale target, default 6016), `--scale N` (model scale, default 4),
`--model NAME` (force a model), `--no-downscale` (keep raw 4x).

## Model routing & the supersample step

| Content | Model | Fallback |
|---------|-------|----------|
| `--type photo` / `auto` | `ultrasharp-4x` | `realesrgan-x4plus` |
| `--type art` | `digital-art-4x` | `realesrgan-x4plus-anime` |

We always upscale **4x** and then **Lanczos-downscale** to the target width
(~2.5K → 4x = ~10K → 6K). This supersampling yields cleaner edges — especially
on flat/geometric art — than asking a model for the ~2.4x we actually need. Pick
the model by content: `--type art` preserves flat color and sharp edges;
`--type photo` favors fine photographic detail.

## Notes

- Wallpapers upscaled before this tool existed used stock `realesrgan-x4plus`;
  re-run them through `--type art`/`--type photo` for a quality bump. Keep the
  4x→downscale-to-6K convention.
- Licenses: Real-ESRGAN binary/models (BSD-3), Upscayl weights (their repo,
  community ESRGAN models). All permissive for personal wallpaper use.
- Higher-quality-but-heavier local paths, deliberately NOT the default:
  **APISR** (best for illustration, needs Python+torch, still one-shot),
  **DAT/Real-HAT-GAN** (best for photos, via **chaiNNer**), and **SUPIR**
  (diffusion, 24GB GPU, non-commercial, hallucinates — avoid for flat art).
  chaiNNer/ComfyUI keep models resident, which is why they are not wired in as
  the idle-friendly default here.

# DMXAPI Image Pipeline

> Give your LLM eyes and a paintbrush.

6 PowerShell scripts + 9-channel chain fallback for vision, image generation and editing. Zero-config after key setup.

[中文文档](README.md)

---

## Prerequisites

| Requirement | Note |
|-------------|------|
| Windows | DPAPI encryption relies on Windows user isolation |
| PowerShell 5.1+ | Built into Windows, no extra install |
| DMXAPI account | Register at https://www.dmxapi.cn, get an API key |
| Model permissions | Enable all 9 models in DMXAPI console (see channel table below) |

## Quick Start

```powershell
# 1. Store your API key (one-time)
.\secure-setup.ps1
# → Choose [1], paste your DMXAPI image key

# 2. Verify channel connectivity (optional)
.\test-pipeline.ps1

# 3. Use
.\describe-image.ps1 -ImagePath "screenshot.png" -Quiet
.\generate-image.ps1 -Prompt "a blue cat" -Quiet -OutputFile "cat.png"
.\edit-image.ps1 -Mode single -Image "photo.jpg" -Prompt "replace background with beach" -Quiet
```

## Scripts

| Script | Purpose | When |
|--------|---------|------|
| `secure-setup.ps1` | Interactive key input → DPAPI-encrypted storage at `~\.dmxapi\` | Once, first run |
| `dmxapi-auth.ps1` | Auth module + 9-channel fallback engine (referenced by the two below) | Called internally |
| `describe-image.ps1` | Vision: image → text description | Per image |
| `generate-image.ps1` | Image gen: text → image | Per generation |
| `edit-image.ps1` | Image editing: modify/composite/inpaint/bgremove | Per edit |
| `test-pipeline.ps1` | Per-channel connectivity diagnostic | First-time check / troubleshooting |
| `test-edit-api.ps1` | Edit API connectivity test | Edit troubleshooting |

### describe-image.ps1

```
-ImagePath       Path to image file (required; png/jpg/jpeg/webp/gif/bmp)
-Prompt          Custom vision prompt (optional; defaults to detailed description)
-Output          Output mode: stdout / file / both
-OutputFile      Output file path (required when Output = file/both)
-Quiet           Quiet mode — description text only, no metadata
-ForceModel      Force a specific model, bypassing fallback chain
-MaxTokens       Max output tokens (default 2048)
```

### generate-image.ps1

```
-Prompt              Image generation prompt (required; 2–4000 chars)
-Size                Size (default 1024x1024; gpt-image-2 supports any WxH, multiple of 16, ≤3840px, 1:3~3:1)
-N                   Number of images 1–4 (default 1)
-Quality             Render quality: low (fast) / medium / high / auto (default)
-Background          Background mode: opaque / auto (default; ⚠️ gpt-image-2 does NOT support transparent)
-OutputFormat        Output format: png (default) / jpeg / webp
-OutputCompression   Compression level 0–100 (jpeg/webp only)
-OutputFile          Output file path
-Quiet               Quiet mode — URL/path only, no metadata
-ForceModel          Force a specific model, bypassing fallback chain
```

When `-OutputFile` is not specified, images are auto-saved to `./output/`.


### edit-image.ps1

Image editing pipeline with 5 modes — all powered by gpt-image-2 `/v1/images/edits` endpoint.

```
-Mode                Edit mode (required): single / multi / twoStage / inpaint / bgremove
-Image               Single image path (required for single/inpaint/bgremove)
-Images              Image path array (required for multi; max 9)
-Prompt              Edit instruction (required for single/multi/inpaint; max 32000 chars)
-Mask                Mask image (inpaint optional; PNG + alpha channel, transparent = edit area)
-Stage1Images        Stage 1 input (required for twoStage; group photo + body reference)
-Stage2Images        Stage 2 input (required for twoStage; face references, ≥1)
-Size                Output size (default 1024x1024; supports arbitrary WxH)
-Quality             Render quality: low / medium / high / auto (default)
-Background          Background mode: opaque / auto (default; ⚠️ transparent not supported by gpt-image-2)
-OutputFormat        Output format: png (default) / jpeg / webp
-OutputCompression   Compression level 0–100 (jpeg/webp only)
-Prompt1             Stage 1 custom prompt (twoStage optional)
-Prompt2             Stage 2 custom prompt (twoStage optional)
-OutputFile          Output file path
-ForceModel          Force a specific model, bypassing fallback chain
-Quiet               Quiet mode — path only, no metadata
```

**5 Modes:**

| Mode | Purpose | Example |
|------|---------|---------|
| `single` | Single-image edit (color/style/lighting/object removal) | `.\edit-image.ps1 -Mode single -Image "photo.jpg" -Prompt "replace background with beach"` |
| `multi` | Multi-image composite (person swap/scene fusion) | `.\edit-image.ps1 -Mode multi -Images @("group.jpg", "person.jpg") -Prompt "replace leftmost person with person in image 2"` |
| `twoStage` | Two-stage face replacement (body→face refinement, highest quality) | `.\edit-image.ps1 -Mode twoStage -Stage1Images @("group.jpg", "fullbody.jpg") -Stage2Images @("face1.jpg", "face2.jpg")` |
| `inpaint` | Mask-based edit (local fix/object removal/canvas extension) | `.\edit-image.ps1 -Mode inpaint -Image "photo.jpg" -Mask "mask.png" -Prompt "add a palm tree in masked area"` |
| `bgremove` | Background removal (solid white output) | `.\edit-image.ps1 -Mode bgremove -Image "product.jpg"` |

⚠️ **bgremove note**: gpt-image-2 does not support transparent backgrounds (`Background=transparent` returns 400). bgremove outputs solid white background. Use remove.bg or similar downstream tools for true transparency.

⚠️ **twoStage note**: Single-stage ~60–300s, two-stage ~6–10min. Most scenarios work with single `multi` mode + multiple reference images. Use twoStage only when identity fidelity is critical.

## Agent Configuration

If you use Claude Code, CherryStudio, or similar agents, add the rules below to your agent's persona file (`SOUL.md` or `CLAUDE.md`). The agent will auto-detect the right path for each visual request. Replace `./scripts/` with your actual script directory.

See [README.md](README.md) for the full Chinese template. The template covers four visual channels with a scene decision tree:

```
Channel 1: Browser snapshot/screenshot (preferred — free & instant)
  → For web pages, text/error extraction, UI inspection
Channel 2: describe-image.ps1 (VLM — on demand)
  → For local images, photos, charts, multi-image comparison
Channel 3: generate-image.ps1 (image generation)
  → For text-to-image, or restyling existing images (describe → generate)
Channel 4: edit-image.ps1 (image editing)
  → For modifying, compositing, inpainting, or removing backgrounds
```

## Channel Architecture

### Image Generation (6 channels · 3 tiers)

| Tier | Channel | Highlights |
|------|---------|------------|
| T1 | gpt-image-2 | Industry leader: 99% text rendering, ELO 1512 |
| T1 | gpt-image-2-ssvip | Same model, different resource pool (T1 backup) |
| T2 | gemini-3.1-flash-image-preview | Nano Banana 2: 9.3/10 realism, ultra-low cost |
| T2 | gemini-2.5-flash-image | Stable anchor |
| T3 | doubao-seedream-4-5-251128 | Fallback, Chinese ecosystem |
| T3 | doubao-seedream-4-0-250828 | Last resort |

### Vision (3 channels · 2 tiers)

| Tier | Channel | Highlights |
|------|---------|------------|
| T1 | Doubao-1.5-vision-pro-32k | Native Chinese VLM, 32K context |
| T2 | gemini-2.5-flash | Strong English, good generalist |
| T2 | gemini-2.5-flash-ssvip | Same model, different pool (T2 backup) |

**Fallback logic**: Same-tier parallel switching → cross-tier degradation → error only when all channels exhausted. Single channel failures are transparent to the user.

## Security

- API key stored via Windows DPAPI encryption (`~\.dmxapi\`), bound to current user + machine
- Scripts contain zero hardcoded keys
- Encrypted files cannot be decrypted if copied to another machine or user
- Sharing these scripts does not expose your key

## FAQ

**All channels failed?**  
Run `.\test-pipeline.ps1` to diagnose. Verify: ① DMXAPI balance sufficient ② All 9 models enabled in console ③ Network ok.

**Seedream 4.5 HTTP 403?**  
Known DMXAPI-side issue. The fallback engine auto-skips this channel — no impact on normal usage.

**How to switch API provider?**  
Edit `$DMXAPI_BASE_URL` and `$ModelChannels` in `dmxapi-auth.ps1`.

---

Author: Xi Ewell · Duke Ewell Laboratory  
License: [CC BY-NC-SA 4.0](LICENSE)

# DMXAPI Image Pipeline

> Give your LLM eyes and a paintbrush.

4 PowerShell scripts + 9-channel chain fallback for vision and image generation. Zero-config after key setup.

[中文文档](README_CN.md)

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
```

## Scripts

| Script | Purpose | When |
|--------|---------|------|
| `secure-setup.ps1` | Interactive key input → DPAPI-encrypted storage at `~\.dmxapi\` | Once, first run |
| `dmxapi-auth.ps1` | Auth module + 9-channel fallback engine (referenced by the two below) | Called internally |
| `describe-image.ps1` | Vision: image → text description | Per image |
| `generate-image.ps1` | Image gen: text → image | Per generation |
| `test-pipeline.ps1` | Per-channel connectivity diagnostic | First-time check / troubleshooting |

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
-Prompt          Image generation prompt (required; 2–4000 chars)
-Size            Size: 1024x1024 / 1024x1536 / 1536x1024 (default 1024x1024)
-N               Number of images 1–4 (default 1)
-OutputFile      Output file path
-Quiet           Quiet mode — URL/path only, no metadata
-ForceModel      Force a specific model, bypassing fallback chain
```

When `-OutputFile` is not specified, images are auto-saved to `./output/`.

## Agent Configuration

If you use Claude Code, CherryStudio, or similar agents, add the rules below to your agent's persona file (`SOUL.md` or `CLAUDE.md`). The agent will auto-detect the right path for each visual request. Replace `./scripts/` with your actual script directory.

See [README_CN.md](README_CN.md) for the full Chinese template. The template covers three visual channels with a scene decision tree:

```
Channel 1: Browser snapshot/screenshot (preferred — free & instant)
  → For web pages, text/error extraction, UI inspection
Channel 2: describe-image.ps1 (VLM — on demand)
  → For local images, photos, charts, multi-image comparison
Channel 3: generate-image.ps1 (image generation)
  → For text-to-image, or restyling existing images (describe → generate)
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
License: [CC BY-NC-ND 4.0](LICENSE)

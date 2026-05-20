# DMXAPI Image Pipeline · 图像管道

> Give your LLM eyes and a paintbrush. &nbsp;|&nbsp; 给没有视觉能力的 LLM 装上眼睛和画笔。

4 PowerShell scripts + 9-channel chain fallback for vision and image generation. Zero-config after key setup.  
4 个 PowerShell 脚本 + 9 通道链式容错，识图和生图开箱即用。

---

## Prerequisites / 前置条件

| Requirement | Note |
|-------------|------|
| Windows | DPAPI encryption relies on Windows user isolation |
| PowerShell 5.1+ | Built into Windows, no extra install |
| DMXAPI account | Register at https://www.dmxapi.cn, get an API key |
| Model permissions | Enable all 9 models in DMXAPI console (see channel table below) |

## Quick Start / 快速开始

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

## Scripts / 脚本说明

| Script | Purpose | When |
|--------|---------|------|
| `secure-setup.ps1` | Interactive key input → DPAPI-encrypted storage at `~\.dmxapi\` | Once, first run |
| `dmxapi-auth.ps1` | Auth module + 9-channel fallback engine (referenced by the two below) | Called internally |
| `describe-image.ps1` | Vision: image → text description | Per image |
| `generate-image.ps1` | Image gen: text → image | Per generation |
| `test-pipeline.ps1` | Per-channel connectivity diagnostic | First-time check / troubleshooting |

### describe-image.ps1

```
-ImagePath       Path to image file (required)
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

## Agent Configuration / Agent 自动调用

If you use Claude Code, CherryStudio, or similar agents, add the following rules to your agent's persona file (`SOUL.md` or `CLAUDE.md`). The agent will auto-detect the right path for each visual request.

Replace `./scripts/` with your actual script directory.

```markdown
## Image & Visual Capability

My base model cannot see images or generate them. I have three visual channels:

| Channel | Tool | Cost | Use Case |
|---------|------|------|----------|
| 1 | Browser `snapshot` | Free · instant | Web text / errors / UI text extraction |
| 2 | `describe-image.ps1` | VLM API | Real images / charts / photo understanding |
| 3 | `generate-image.ps1` | Image gen API | Text → image generation |

### Scene Decision Tree (Judge first, then invoke)

```
Visual request received
├── Target is a webpage / URL?
│   ├── "Read content / errors / text" → snapshot (free, instant)
│   ├── "See layout / design / what it looks like" → screenshot
│   ├── Snapshot unavailable → fallback to web_fetch_exa
│   └── Login / interaction needed → open + showWindow=true + snapshot
│
├── Target is a local image file?
│   ├── Single image description → describe-image.ps1 -Quiet
│   ├── Multi-image comparison → parallel describe-image.ps1 calls
│   └── Chart / data extraction → describe-image.ps1 + custom Prompt
│
└── Target is image generation?
    ├── Generate from scratch → generate-image.ps1 -Prompt + -Quiet
    └── Restyle existing image → describe first → merge with new requirements → generate
```

### Script Paths

```
./scripts/describe-image.ps1   # Vision (Vision API)
./scripts/generate-image.ps1   # Image Generation (ImageGen API)
./scripts/test-pipeline.ps1    # Channel diagnostic
```

### Channel 1: Browser snapshot/screenshot (Preferred — free & instant)

Do NOT invoke `describe-image.ps1` for these. Use Browser tools directly:
- User sends a URL saying "check this out" / "open X" / "any errors?"
- Web page content extraction, error message reading, UI layout inspection
- `snapshot` for text content; `screenshot` for visual layout

### Channel 2: describe-image.ps1 (VLM — on demand)

Invoke `describe-image.ps1` when:
- User sends a local image file (photo, saved screenshot, chart)
- User says "describe this image" / "what's in this picture?"
- Multi-image comparison — invoke in parallel

```powershell
powershell -File "./scripts/describe-image.ps1" -ImagePath "<path>" -Quiet
```

### Channel 3: generate-image.ps1 (Image generation)

Invoke `generate-image.ps1` when:
- User says "generate an image" / "draw X" / "make a poster"
- User describes a visual requirement and wants image output

```powershell
powershell -File "./scripts/generate-image.ps1" -Prompt "<description>" -Quiet
```
Optional: `-Size "1024x1024"`, `-N 4`.

### Combo Workflows

- **Web → screenshot → vision**: "What does this site look like?" → screenshot → describe if deep analysis needed
- **Vision → generation**: "Restyle this image as X" → describe first → merge description → generate
- **Pipeline diagnostic**: "Image features broken" → run `test-pipeline.ps1`
```

## Channel Architecture / 通道架构

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

## Security / 安全

- API key stored via Windows DPAPI encryption (`~\.dmxapi\`), bound to current user + machine
- Scripts contain zero hardcoded keys
- Encrypted files cannot be decrypted if copied to another machine or user
- Sharing these scripts does not expose your key

## FAQ / 常见问题

**Q: All channels failed? / 所有通道都挂了？**  
Run `.\test-pipeline.ps1` to diagnose. Verify: ① DMXAPI balance sufficient ② All 9 models enabled in console ③ Network ok.

**Q: Seedream 4.5 returns HTTP 403?**  
Known DMXAPI-side issue. The fallback engine auto-skips this channel — no impact on normal usage.

**Q: Chinese text garbled in output? / 中文乱码？**  
Check PS ≥ 5.1. Scripts have built-in `[Console]::OutputEncoding = UTF8` fix.

**Q: How to switch API provider? / 如何换 API 服务商？**  
Edit `$DMXAPI_BASE_URL` and `$ModelChannels` in `dmxapi-auth.ps1`.

---

Author / 作者：Xi Ewell · Duke Ewell Laboratory  
License: [CC BY-NC-ND 4.0](LICENSE)

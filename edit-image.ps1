<#
.SYNOPSIS
    图片编辑管道——图生图（Image-to-Image）
    支持 5 种模式：single / multi / twoStage / inpaint / bgremove
    内置 2 通道容错：gpt-image-2-ssvip > gpt-image-2
.DESCRIPTION
    用法:
      # 单图编辑
      .\edit-image.ps1 -Mode single -Image "photo.jpg" -Prompt "将背景替换为海滩"

      # 多图合成（人物替换等）
      .\edit-image.ps1 -Mode multi -Images @("group.jpg", "person.jpg") `
          -Prompt "将图1最左侧的人替换为图2中的人，保留胸牌"

      # 两阶段人物替换（推荐·2026-05-25 Ewell 验证通过）
      .\edit-image.ps1 -Mode twoStage `
          -Stage1Images @("合照.jpg", "全身照.jpg") `
          -Stage2Images @("面部1.jpg", "面部2.jpg", "面部3.jpg", "面部4.jpg")

      # 遮罩编辑/局部修补（2026-05-26 新增）
      .\edit-image.ps1 -Mode inpaint -Image "photo.jpg" -Mask "mask.png" `
          -Prompt "在遮罩区域添加一棵棕榈树"

      # 背景移除+白底输出（2026-05-26 新增，05-26 修正：gpt-image-2 不支持透明背景）
      .\edit-image.ps1 -Mode bgremove -Image "product.jpg"

      # 指定质量/输出格式（2026-05-26 新增）
      .\edit-image.ps1 -Mode single -Image "photo.jpg" -Prompt "..." `
          -Quality low -OutputFormat jpeg -OutputCompression 85

    两阶段方法论（2026-05-25 · tom 分析确认）:
      阶段1: 身体替换 —— 隔离大结构变化，避免注意力分散
      阶段2: 面部精修 —— 专注 identity matching + anti-smoothing 约束

    遮罩编辑（inpaint）:
      提供 Mask（PNG + alpha 通道）时，仅编辑透明区域
      不提供 Mask 时，模型从 prompt 推断编辑区域
      适用：物体移除、局部修补、画布扩展(outpainting)

    通道: gpt-image-2-ssvip (T1) → gpt-image-2 (T2)
    端点: POST /v1/images/edits (multipart/form-data)
    ⚠️ 参数对齐 gpt-image-2 官方文档（2026-05-26 修正）：
       - quality 参数现已正确传递至 API（此前是死参数）
       - ⚠️ gpt-image-2 不支持 Background=transparent（仅 opaque/auto）
       - input_fidelity 已禁用（始终高保真，传了会报错）
       - size 支持任意 WxH（16 倍数，≤3840px，1:3~3:1）
    ⚠️ HTTP headers 路由机制（2026-05-26 发现）：DMXAPI 根据 User-Agent + Accept 做路由决策，
       不加标准 headers → 降级后端（效果差）；加 DMXAPI/1.0.0 UA → 生产后端（效果好）
    ⚠️ 两阶段处理大图/多图可能需要 6-15 分钟

    安全: Key 从 DPAPI 加密文件读取，API 调用通过 Python subprocess（requests 库处理 multipart）

.ImageEdit 通道设计（2026-05-25 · 实测验证）:
    T1 — gpt-image-2-ssvip → T2 — gpt-image-2
          端点: /v1/images/edits · 超时: 360s
          ✅ 已验证：双图人物替换 211s 成功
          ❌ flux-kontext — 403 无权访问
          ❌ wan2.7-image-pro — 403 无权访问

.NOTES
    作者: Xi Ewell · Duke Ewell Laboratory
    GitHub: https://github.com/Trojan-Seahorse/visus
    依赖: dmxapi-auth.ps1（同目录）· Python 3 + requests 库
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="编辑模式: single / multi / twoStage / inpaint / bgremove")]
    [ValidateSet("single", "multi", "twoStage", "inpaint", "bgremove")]
    [string]$Mode,

    [Parameter(HelpMessage="单图/inpaint/bgremove 模式：待编辑图片路径")]
    [string]$Image,

    [Parameter(HelpMessage="多图模式：输入图片路径数组")]
    [string[]]$Images,

    [Parameter(HelpMessage="inpaint 模式：遮罩图片（PNG + alpha 通道），透明=编辑区。可选，不提供时模型从 prompt 推断。")]
    [string]$Mask,

    [Parameter(HelpMessage="编辑指令提示词（single/multi/inpaint 必填，twoStage/bgremove 可选）")]
    [string]$Prompt,

    [Parameter(HelpMessage="twoStage 模式：阶段1输入图（合照 + 全身照等身体参考）")]
    [string[]]$Stage1Images,

    [Parameter(HelpMessage="twoStage 模式：阶段2输入图（面部参考照，至少1张）")]
    [string[]]$Stage2Images,

    [Parameter(HelpMessage="twoStage 模式：阶段1自定义 prompt（可选，有默认值）")]
    [string]$Prompt1,

    [Parameter(HelpMessage="twoStage 模式：阶段2自定义 prompt（可选，有默认值）")]
    [string]$Prompt2,

    [Parameter(HelpMessage="输出图片路径")]
    [string]$OutputFile,

    [Parameter(HelpMessage="图片尺寸")]
    [ValidateSet("1024x1024", "1024x1536", "1536x1024", "auto")]
    [string]$Size = "1024x1024",

    [Parameter(HelpMessage="背景处理: opaque（不透明）/ auto（自动）| ⚠️ gpt-image-2 不支持 transparent")]
    [ValidateSet("opaque", "auto")]
    [string]$Background,

    [Parameter(HelpMessage="输出格式: png / jpeg / webp（默认 png）")]
    [ValidateSet("png", "jpeg", "webp")]
    [string]$OutputFormat = "png",

    [Parameter(HelpMessage="输出压缩级别 0-100（仅 jpeg/webp 有效）")]
    [ValidateRange(0, 100)]
    [int]$OutputCompression = -1,

    [Parameter(HelpMessage="生成质量: low / medium / high / auto")]
    [ValidateSet("low", "medium", "high", "auto")]
    [string]$Quality = "auto",

    [Parameter(HelpMessage="生成张数")]
    [ValidateRange(1, 4)]
    [int]$N = 1,

    [Parameter(HelpMessage="强制指定模型（跳过容错链）")]
    [string]$ForceModel,

    [Parameter(HelpMessage="输出去向: stdout / file / both")]
    [ValidateSet("stdout", "file", "both")]
    [string]$Output = "stdout",

    [Parameter(HelpMessage="静默模式——仅输出路径")]
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# ═══════════════════════════════════════════════
# 输出文件扩展名映射
# ═══════════════════════════════════════════════

$extMap = @{ "png" = ".png"; "jpeg" = ".jpg"; "webp" = ".webp" }
$defaultExt = $extMap[$OutputFormat]

# ═══════════════════════════════════════════════
# 输入校验
# ═══════════════════════════════════════════════

$imagePaths = @()
switch ($Mode) {
    "single" {
        if (-not $Prompt -or $Prompt.Length -lt 2) { Write-Error "single 模式必须指定 -Prompt（最少 2 个字符）"; exit 4 }
        if ($Prompt.Length -gt 4000) { Write-Warning "提示词 $($Prompt.Length) 字符，部分 API 可能截断" }
        if (-not $Image) { Write-Error "single 模式必须指定 -Image"; exit 5 }
        if (-not (Test-Path $Image)) { Write-Error "图片不存在: $Image"; exit 5 }
        $imagePaths += (Resolve-Path $Image).Path
    }
    "multi" {
        if (-not $Prompt -or $Prompt.Length -lt 2) { Write-Error "multi 模式必须指定 -Prompt（最少 2 个字符）"; exit 4 }
        if ($Prompt.Length -gt 4000) { Write-Warning "提示词 $($Prompt.Length) 字符，部分 API 可能截断" }
        if (-not $Images -or $Images.Count -lt 2) {
            Write-Error "multi 模式至少 2 张图片"; exit 5
        }
        if ($Images.Count -gt 9) {
            Write-Error "最多 9 张图片，当前: $($Images.Count)"; exit 5
        }
        foreach ($img in $Images) {
            if (-not (Test-Path $img)) { Write-Error "图片不存在: $img"; exit 5 }
            $imagePaths += (Resolve-Path $img).Path
        }
    }
    "inpaint" {
        if (-not $Prompt -or $Prompt.Length -lt 2) { Write-Error "inpaint 模式必须指定 -Prompt（最少 2 个字符）"; exit 4 }
        if ($Prompt.Length -gt 4000) { Write-Warning "提示词 $($Prompt.Length) 字符，部分 API 可能截断" }
        if (-not $Image) { Write-Error "inpaint 模式必须指定 -Image"; exit 5 }
        if (-not (Test-Path $Image)) { Write-Error "图片不存在: $Image"; exit 5 }
        $imagePaths += (Resolve-Path $Image).Path
        # Mask 可选——不提供时模型从 prompt 推断编辑区域
        if ($Mask) {
            if (-not (Test-Path $Mask)) { Write-Error "遮罩图片不存在: $Mask"; exit 5 }
            if ($Mask -notmatch '\.png$') { Write-Warning "遮罩应为 PNG 格式（需 alpha 通道），当前: $Mask" }
        }
    }
    "bgremove" {
        if (-not $Image) { Write-Error "bgremove 模式必须指定 -Image"; exit 5 }
        if (-not (Test-Path $Image)) { Write-Error "图片不存在: $Image"; exit 5 }
        $imagePaths += (Resolve-Path $Image).Path
        # Prompt 可选——有默认值
    }
    "twoStage" {
        # 校验阶段1输入
        if (-not $Stage1Images -or $Stage1Images.Count -lt 2) {
            Write-Error "twoStage 模式 -Stage1Images 至少需要 2 张图片（合照 + 身体参考照）"; exit 5
        }
        if ($Stage1Images.Count -gt 8) { Write-Error "阶段1最多 8 张图片（留 1 个位置给阶段2中间结果）"; exit 5 }
        foreach ($img in $Stage1Images) {
            if (-not (Test-Path $img)) { Write-Error "阶段1图片不存在: $img"; exit 5 }
        }
        # 校验阶段2输入
        if (-not $Stage2Images -or $Stage2Images.Count -lt 1) {
            Write-Error "twoStage 模式 -Stage2Images 至少需要 1 张面部参考图"; exit 5
        }
        if ($Stage2Images.Count -gt 8) { Write-Error "阶段2最多 8 张面部参考图"; exit 5 }
        foreach ($img in $Stage2Images) {
            if (-not (Test-Path $img)) { Write-Error "阶段2图片不存在: $img"; exit 5 }
        }
        # Prompt1/Prompt2 可选——有默认值
        if ($Prompt1 -and $Prompt1.Length -gt 4000) { Write-Warning "阶段1提示词 $($Prompt1.Length) 字符，部分 API 可能截断" }
        if ($Prompt2 -and $Prompt2.Length -gt 4000) { Write-Warning "阶段2提示词 $($Prompt2.Length) 字符，部分 API 可能截断" }
    }
}

# ═══════════════════════════════════════════════
# 加载认证
# ═══════════════════════════════════════════════

$script_dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$auth_module = Join-Path $script_dir "dmxapi-auth.ps1"
if (-not (Test-Path $auth_module)) { Write-Error "找不到 dmxapi-auth.ps1"; exit 1 }
. $auth_module

$apiKey = Get-DmxApiKey -KeyType "image"
if (-not $apiKey) { Write-Error "无法获取 API key"; exit 1 }

# ═══════════════════════════════════════════════
# 默认 Prompt
# ═══════════════════════════════════════════════

# --- twoStage 默认 Prompt ---
$defaultPrompt1 = @'
把合照中最左边穿白色披肩黑色裙子的人替换成参考照片中的人，
但是合照中最左侧人戴的胸牌和挂绳保留，需要看上去毫无破绽。
'@.Trim() -replace "`n", " "

$defaultPrompt2 = @'
参考其他几张照片的人脸，把合照中最左侧人物的人脸替换成
其他几张照片中的人物的脸（其他几张照片都是同一个人）。
注意所有人物的面部不要磨皮过度，要保持合照原来的画质。
'@.Trim() -replace "`n", " "

# --- bgremove 默认 Prompt ---
$defaultBgRemovePrompt = @'
Remove the background completely. Make it a solid white background.
Keep only the main subject with clean edges. No halos, no fringing.
Preserve all details of the subject. Do not alter colors or lighting.
'@.Trim() -replace "`n", " "

# twoStage 模式：使用 Prompt1/Prompt2 或默认值
if ($Mode -eq "twoStage") {
    if (-not $Prompt1) { $Prompt1 = $defaultPrompt1 }
    if (-not $Prompt2) { $Prompt2 = $defaultPrompt2 }
}

# bgremove 模式：使用 Prompt 或默认值
# ⚠️ gpt-image-2 不支持 Background=transparent，默认用 auto（模型自动选择白底/纯色背景）
if ($Mode -eq "bgremove") {
    if (-not $Prompt) { $Prompt = $defaultBgRemovePrompt }
    if (-not $Background) { $Background = "auto" }
}

# ═══════════════════════════════════════════════
# 通道定义
# ═══════════════════════════════════════════════

if ($ForceModel) {
    $channels = @(@{ Model = $ForceModel; Label = "手动指定: $ForceModel" })
} else {
    $channels = @(
        @{ Model = "gpt-image-2-ssvip"; Label = "T1 gpt-image-2 SSVIP" }
        @{ Model = "gpt-image-2";        Label = "T2 gpt-image-2" }
    )
}

# ═══════════════════════════════════════════════
# Python 图片编辑脚本（模板）
# 支持 mask / background / output_format / output_compression / quality
# ═══════════════════════════════════════════════

$pythonTemplate = @'
import sys, json, base64, requests, os

api_key           = sys.argv[1]
model             = sys.argv[2]
size              = sys.argv[3]
n                 = int(sys.argv[4])
prompt            = sys.argv[5]
mask_path         = sys.argv[6]   # "NONE" or file path
background        = sys.argv[7]   # "NONE" or transparent/opaque/auto
output_format     = sys.argv[8]   # "NONE" or png/jpeg/webp
output_compression = sys.argv[9]  # "NONE" or 0-100
quality           = sys.argv[10]  # "NONE" or low/medium/high/auto
images            = sys.argv[11:] # file paths

files = []
try:
    for i, img_path in enumerate(images):
        ext = img_path.rsplit('.', 1)[-1].lower()
        mime_map = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"}
        mime = mime_map.get(ext, "image/png")
        filename = f"img{i}.{ext}"
        files.append(("image", (filename, open(img_path, "rb"), mime)))

    # Add mask if provided (PNG with alpha channel — transparent = edit region)
    if mask_path != "NONE" and os.path.exists(mask_path):
        mask_ext = mask_path.rsplit('.', 1)[-1].lower()
        files.append(("mask", (f"mask.{mask_ext}", open(mask_path, "rb"), "image/png")))

    data = {"model": model, "prompt": prompt, "size": size, "n": n}

    if quality != "NONE":
        data["quality"] = quality
    if background != "NONE":
        data["background"] = background
    if output_format != "NONE":
        data["output_format"] = output_format
    if output_compression != "NONE":
        data["output_compression"] = int(output_compression)

    resp = requests.post(
        "https://www.dmxapi.cn/v1/images/edits",
        data=data, files=files,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Accept": "application/json",
            "User-Agent": "DMXAPI/1.0.0 (https://www.dmxapi.com)"
        },
        timeout=360
    )

    result = resp.json()
    if resp.status_code != 200:
        print(json.dumps({"error": f"HTTP {resp.status_code}: {result}"}))
        sys.exit(1)

    if "data" in result and len(result["data"]) > 0:
        img = result["data"][0]
        if "b64_json" in img:
            print(img["b64_json"])
        elif "url" in img:
            print("URL:" + img["url"])
        else:
            print(json.dumps({"error": "no image data in response"}))
    elif "error" in result:
        print(json.dumps({"error": str(result["error"])}))
    else:
        print(json.dumps(result))

except requests.exceptions.Timeout:
    print(json.dumps({"error": "TIMEOUT after 360s"}))
    sys.exit(1)
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(1)
finally:
    for _, (_, f, _) in files:
        f.close()
'@

# ═══════════════════════════════════════════════
# 核心编辑函数（封装链式容错）
# ═══════════════════════════════════════════════

function Invoke-ImageEdit {
    param(
        [string[]]$ImagePaths,
        [string]$EditPrompt,
        [string]$StageName = "",
        [string]$MaskPath = "NONE",
        [string]$BgMode = "NONE",
        [string]$OutFormat = "NONE",
        [string]$OutCompression = "NONE",
        [string]$Quality = "NONE"
    )

    $totalCh = $channels.Count
    $errs = @()
    $bytes = $null
    $meta = $null
    $prefix = if ($StageName) { "[$StageName] " } else { "" }

    for ($i = 0; $i -lt $totalCh; $i++) {
        $ch = $channels[$i]
        $label = $ch.Label
        $model = $ch.Model

        if (-not $Quiet) { Write-Host "$prefix[$($i+1)/$totalCh] $label ($model)" -ForegroundColor DarkGray }

        # 写入临时 Python 脚本
        $tmpPy = [System.IO.Path]::GetTempFileName() + ".py"
        [System.IO.File]::WriteAllText($tmpPy, $pythonTemplate, [System.Text.Encoding]::UTF8)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # python <script> <apiKey> <model> <size> <n> <prompt> <mask> <background> <output_format> <output_compression> <quality> <image1> [image2...]
            $allArgs = @($tmpPy, $apiKey, $model, $Size, "$N", $EditPrompt,
                         $MaskPath, $BgMode, $OutFormat, $OutCompression, $Quality) + $ImagePaths
            $output = & python $allArgs 2>&1
            $exitCode = $LASTEXITCODE
            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            if ($exitCode -ne 0 -or $output -match '"error"') {
                throw "Python: $output"
            }

            if ($output -match '^URL:(.+)') {
                $wc = New-Object System.Net.WebClient
                $bytes = $wc.DownloadData($Matches[1].Trim())
            } elseif ($output.Length -gt 100) {
                $bytes = [Convert]::FromBase64String($output.Trim())
            } else {
                throw "Unexpected: $output"
            }

            $meta = "$prefix[$label | 第$($i+1)次尝试 | ${elapsed}s]"
            if (-not $Quiet) { Write-Host "  [✓] ${elapsed}s" -ForegroundColor Green }
            break
        } catch {
            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            if (-not $Quiet) { Write-Host "  [✗] $_ (${elapsed}s)" -ForegroundColor Yellow }
            $errs += "$prefix$label -> $_"
        } finally {
            if (Test-Path $tmpPy) { Remove-Item $tmpPy -Force }
        }
    }

    if (-not $bytes) {
        throw "图片编辑失败: 所有 $totalCh 个通道均不可用`n$($errs -join "`n")"
    }

    return @{ Bytes = $bytes; Meta = $meta; Errors = $errs }
}

# ═══════════════════════════════════════════════
# 构建额外参数
# ═══════════════════════════════════════════════

# Mask path（仅 inpaint 模式）
$maskArg = "NONE"
if ($Mode -eq "inpaint" -and $Mask) {
    $maskArg = (Resolve-Path $Mask).Path
}

# Background 参数
$bgArg = "NONE"
if ($Background) { $bgArg = $Background }

# Output format 参数
$fmtArg = "NONE"
if ($OutputFormat -and $OutputFormat -ne "png") { $fmtArg = $OutputFormat }

# Output compression 参数
$cmpArg = "NONE"
if ($OutputCompression -ge 0) { $cmpArg = "$OutputCompression" }

# Quality 参数（之前是死参数——现在真正传递）
$qualityArg = "NONE"
if ($Quality -and $Quality -ne "auto") { $qualityArg = $Quality }

# ═══════════════════════════════════════════════
# 执行编辑
# ═══════════════════════════════════════════════

$stage1Meta = ""
$resultBytes = $null
$resultMeta = $null

# 将公共参数打包
$extraArgs = @{
    MaskPath        = $maskArg
    BgMode          = $bgArg
    OutFormat       = $fmtArg
    OutCompression  = $cmpArg
    Quality         = $qualityArg
}

if ($Mode -eq "twoStage") {
    # ── 阶段 1：身体替换 ──
    $stage1Paths = @()
    foreach ($img in $Stage1Images) { $stage1Paths += (Resolve-Path $img).Path }

    if (-not $Quiet) { Write-Host "`n════ 阶段1/2：身体替换 ════" -ForegroundColor Cyan }
    try {
        $stage1 = Invoke-ImageEdit -ImagePaths $stage1Paths -EditPrompt $Prompt1 -StageName "阶段1" @extraArgs
        $stage1Meta = $stage1.Meta
    } catch {
        Write-Error "阶段1失败: $_"
        exit 2
    }

    # 保存中间结果
    $intermediateDir = Join-Path (Split-Path -Parent $script_dir) "output"
    if (-not (Test-Path $intermediateDir)) { New-Item -Path $intermediateDir -ItemType Directory -Force | Out-Null }
    $intermediatePath = Join-Path $intermediateDir "lumen_stage1_$(Get-Date -Format 'yyyyMMddHHmmss').png"
    [System.IO.File]::WriteAllBytes($intermediatePath, $stage1.Bytes)
    if (-not $Quiet) { Write-Host "  [→] 中间结果: $intermediatePath" -ForegroundColor DarkGray }

    # ── 阶段 2：面部精修 ──
    $stage2Paths = @($intermediatePath)
    foreach ($img in $Stage2Images) { $stage2Paths += (Resolve-Path $img).Path }

    if (-not $Quiet) { Write-Host "`n════ 阶段2/2：面部精修 ════" -ForegroundColor Cyan }
    try {
        $stage2 = Invoke-ImageEdit -ImagePaths $stage2Paths -EditPrompt $Prompt2 -StageName "阶段2" @extraArgs
        $resultBytes = $stage2.Bytes
        $resultMeta = "$($stage2.Meta) (← 阶段1: $stage1Meta)"
    } catch {
        Write-Error "阶段2失败（阶段1中间结果已保存: $intermediatePath）: $_"
        exit 2
    }
} else {
    # ── single / multi / inpaint / bgremove 模式 ──
    try {
        $result = Invoke-ImageEdit -ImagePaths $imagePaths -EditPrompt $Prompt @extraArgs
        $resultBytes = $result.Bytes
        $resultMeta = $result.Meta
    } catch {
        Write-Error $_
        exit 2
    }
}

# ═══════════════════════════════════════════════
# 输出
# ═══════════════════════════════════════════════

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$output_dir = Join-Path (Split-Path -Parent $script_dir) "output"
if (-not (Test-Path $output_dir)) { New-Item -Path $output_dir -ItemType Directory -Force | Out-Null }

if ($OutputFile) {
    $savePath = $OutputFile
} else {
    $modeTag = switch ($Mode) {
        "inpaint"  { "inpaint" }
        "bgremove" { "bgremove" }
        "twoStage" { "edit" }
        default    { "edit" }
    }
    $savePath = Join-Path $output_dir "lumen_${modeTag}_$(Get-Date -Format 'yyyyMMddHHmmss')$defaultExt"
}

[System.IO.File]::WriteAllBytes($savePath, $resultBytes)

if ($OutputFile -and $Output -eq "stdout") { $Output = "both" }

switch ($Output) {
    "stdout" {
        if (-not $Quiet) { Write-Host $resultMeta -ForegroundColor DarkGray }
        Write-Output $savePath
    }
    "file" {
        if (-not $Quiet) { Write-Host "[✓] $savePath  $resultMeta" -ForegroundColor Green }
    }
    "both" {
        if (-not $Quiet) { Write-Host $resultMeta -ForegroundColor DarkGray }
        Write-Output $savePath
        if (-not $Quiet) { Write-Host "[✓] $savePath" -ForegroundColor Green }
    }
}

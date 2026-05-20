<#
.SYNOPSIS
    图片识图管道——将图片发送给 VLM，返回详细文本描述
    供 DeepSeek V4 Pro 等无视觉能力的模型消费
    内置 3 通道链式容错：Doubao Vision Pro (T1) > Gemini Flash (T2) > Gemini SSVIP (T2)
.DESCRIPTION
    用法:
      .\describe-image.ps1 -ImagePath "C:\screenshot.png"
      .\describe-image.ps1 -ImagePath "C:\photo.jpg" -Prompt "这张图里有什么文字？逐字列出"
      .\describe-image.ps1 -ImagePath "C:\image.png" -Output file -OutputFile "desc.txt"

    默认自动按优先级重试 3 个 VLM 通道，无需手动指定模型。
    如需强制指定单模型: -ForceModel "gemini-2.5-flash"

    安全: Key 从 DPAPI 加密文件读取，不暴露于命令行参数或日志

.Vision 通道设计（2026-05-20 · tom 分析最终版）:
    T1 — Doubao-1.5-vision-pro-32k (5.0折 ~¥3-5/次)
          中文原生 VLM，32K 上下文，中文 UI/文档/OCR 场景最优
    T2 — gemini-2.5-flash (6.8折 ~¥3-5/次)
          → gemini-2.5-flash-ssvip (原价 ~¥4-7/次，溢价 1.46x 可接受)
          已验证兼容，英文强，通用性好
    排除: qwen2.5-vl-72b-instruct — 7-10x Doubao 价格，零质量证据
         doubao-seed-1-6-vision-250815 — 已被 Doubao-1.5-vision-pro 取代
.NOTES
    作者: Xi Ewell · Duke Ewell Laboratory
    依赖: dmxapi-auth.ps1（同目录，含容错引擎）
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="图片文件路径")]
    [ValidateScript({
        if (-not (Test-Path $_)) { throw "文件不存在: $_" }
        $ext = [System.IO.Path]::GetExtension($_).TrimStart('.').ToLower()
        if ($ext -notin @('png','jpg','jpeg','webp','gif','bmp')) { throw "不支持的图片格式: .$ext（支持 png/jpg/jpeg/webp/gif/bmp）" }
        if ((Get-Item $_).Length -eq 0) { throw "图片文件为空" }
        if ((Get-Item $_).Length -gt 50MB) { throw "图片文件过大 (最大 50MB)" }
        return $true
    })]
    [string]$ImagePath,

    [Parameter(HelpMessage="自定义提示词")]
    [string]$Prompt,

    [Parameter(HelpMessage="强制指定单模型（跳过容错链）")]
    [string]$ForceModel,

    [Parameter(HelpMessage="输出去向: stdout / file / both")]
    [ValidateSet("stdout", "file", "both")]
    [string]$Output = "stdout",

    [Parameter(HelpMessage="输出文件路径（Output 为 file/both 时必填）")]
    [string]$OutputFile,

    [Parameter(HelpMessage="最大输出 token 数")]
    [int]$MaxTokens = 2048,

    [Parameter(HelpMessage="每个通道超时秒数")]
    [int]$TimeoutSec = 120,

    [Parameter(HelpMessage="静默模式——仅输出描述文本，不输出元信息")]
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# ── 加载认证模块 ──
$script_dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$auth_module = Join-Path $script_dir "dmxapi-auth.ps1"
if (-not (Test-Path $auth_module)) {
    Write-Error "找不到 dmxapi-auth.ps1，请确保两个脚本在同一目录下"
    exit 1
}
. $auth_module

# ── 图片 → Base64 ──
$image_bytes = [System.IO.File]::ReadAllBytes((Resolve-Path $ImagePath))
$base64 = [Convert]::ToBase64String($image_bytes)
$ext = [System.IO.Path]::GetExtension($ImagePath).TrimStart('.').ToLower()
$mime = switch ($ext) {
    "png"  { "image/png" }
    "jpg"  { "image/jpeg" }
    "jpeg" { "image/jpeg" }
    "webp" { "image/webp" }
    "gif"  { "image/gif" }
    default { "image/png" }
}

# ── 默认 Prompt ──
if (-not $Prompt) {
    $Prompt = @"
详细描述这张图片的内容。请包括：
1. 图中有什么物体/人物/场景
2. 文字内容（如果有文字，请逐行转录，中文优先保持原样）
3. 颜色、构图、氛围
4. 任何数据、数字、图表内容
5. UI 元素（如果是界面截图，描述按钮、菜单、布局）
请用中文回答，尽可能详尽。
"@
}

# ── 构建请求体 ──
$body = @{
    model    = "__placeholder__"  # 容错引擎会注入
    messages = @(
        @{
            role    = "user"
            content = @(
                @{ type = "image_url"; image_url = @{ url = "data:$mime;base64,$base64" } },
                @{ type = "text"; text = $Prompt }
            )
        }
    )
    max_tokens  = $MaxTokens
    temperature = 0.1
} | ConvertTo-Json -Depth 6

# ── 决定通道列表 ──
if ($ForceModel) {
    $channels = @(@{ Model = $ForceModel; Label = "手动指定: $ForceModel" })
} else {
    $channels = $ModelChannels.Vision
}

# ── 带容错调用 ──
try {
    $result = Invoke-DmxApiWithFallback `
        -ChannelList $channels `
        -Endpoint "chat/completions" `
        -Body $body `
        -TimeoutSec $TimeoutSec

    $description = $result.Response.choices[0].message.content
    $prompt_tokens  = $result.Response.usage.prompt_tokens
    $completion_tokens = $result.Response.usage.completion_tokens
    $meta = "[通道: $($result.Channel) | 第$($result.Attempt)次尝试 | 耗时: $($result.ElapsedSec)s | prompt: ${prompt_tokens}tk | output: ${completion_tokens}tk]"

} catch {
    Write-Error "识图失败: 所有通道均不可用`n$_"
    exit 2
}

# ── 修复 PS 5.1 中文 Windows 编码 ——
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── 输出 ──
switch ($Output) {
    "stdout" {
        if (-not $Quiet) { Write-Host $meta -ForegroundColor DarkGray }
        Write-Output $description
    }
    "file" {
        if (-not $OutputFile) { Write-Error "Output=file 时必须指定 -OutputFile"; exit 3 }
        $description | Out-File -FilePath $OutputFile -Encoding utf8
        if (-not $Quiet) { Write-Host "[✓] 已写入 $OutputFile ($($result.Channel))" -ForegroundColor Green }
    }
    "both" {
        if (-not $OutputFile) { Write-Error "Output=both 时必须指定 -OutputFile"; exit 3 }
        if (-not $Quiet) { Write-Host $meta -ForegroundColor DarkGray }
        Write-Output $description
        $description | Out-File -FilePath $OutputFile -Encoding utf8
        if (-not $Quiet) { Write-Host "[✓] 同时写入 $OutputFile" -ForegroundColor Green }
    }
}


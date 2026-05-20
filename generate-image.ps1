<#
.SYNOPSIS
    图片生图管道——调用多通道容错引擎生成图片
    内置 6 通道链式容错：T1(gpt-image-2) > T2(Gemini) > T3(Seedream)
.DESCRIPTION
    用法:
      .\generate-image.ps1 -Prompt "一只蓝色的猫" -OutputFile "cat.png"
      .\generate-image.ps1 -Prompt "a blue cat" -Size "1024x1024" -N 2
      .\generate-image.ps1 -Prompt "山水画" -Output file -OutputFile "landscape.png"

    默认自动按优先级重试 6 个生图通道，无需手动指定模型。
    如需强制指定单模型: -ForceModel "gpt-image-2"

    安全: Key 从 DPAPI 加密文件读取，不暴露于命令行参数或日志

.ImageGen 通道设计（2026-05-20 · tom 分析最终版）:
    T1 — gpt-image-2 (6.8折) → gpt-image-2-ssvip (同模异池)
          行业标杆：文字 99%，ELO 1512，242 点领先
    T2 — gemini-3.1-flash-image-preview (2.5折 Nano Banana 2)
          → gemini-2.5-flash-image (稳定锚)
          写实 9.3/10，成本极低
    T3 — doubao-seedream-4-5-251128 (4.0 修复版)
          → doubao-seedream-4-0-250828 (终极兜底)
          中文生态兼容，已知缺陷但可兜底
.NOTES
    作者: Xi Ewell · Duke Ewell Laboratory
    依赖: dmxapi-auth.ps1（同目录，含容错引擎）
#>

param(
    [Parameter(Mandatory=$true, HelpMessage="生图提示词")]
    [string]$Prompt,

    [Parameter(HelpMessage="输出图片路径")]
    [string]$OutputFile,

    [Parameter(HelpMessage="图片尺寸")]
    [ValidateSet("1024x1024", "1024x1536", "1536x1024", "1024x768", "768x1024")]
    [string]$Size = "1024x1024",

    [Parameter(HelpMessage="生成张数")]
    [ValidateRange(1, 4)]
    [int]$N = 1,

    [Parameter(HelpMessage="强制指定单模型（跳过容错链）")]
    [string]$ForceModel,

    [Parameter(HelpMessage="输出去向: stdout / file / both")]
    [ValidateSet("stdout", "file", "both")]
    [string]$Output = "stdout",

    [Parameter(HelpMessage="静默模式——仅输出 URL/路径，不输出元信息")]
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# ── 输入校验 ──
if ($Prompt.Length -lt 2) {
    Write-Error "提示词过短（最少 2 个字符）"
    exit 4
}
if ($Prompt.Length -gt 4000) {
    Write-Warning "提示词较长 ($($Prompt.Length) 字符)，部分 API 可能截断到 4000 字符以内"
}

# ── 加载认证模块 ──
$script_dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$auth_module = Join-Path $script_dir "dmxapi-auth.ps1"
if (-not (Test-Path $auth_module)) {
    Write-Error "找不到 dmxapi-auth.ps1，请确保两个脚本在同一目录下"
    exit 1
}
. $auth_module

# ── 构建请求体 ──
$body = @{
    model  = "__placeholder__"  # 容错引擎会注入
    prompt = $Prompt
    size   = $Size
    n      = $N
} | ConvertTo-Json -Depth 4

# ── 决定通道列表 ──
if ($ForceModel) {
    $channels = @(@{ Model = $ForceModel; Label = "手动指定: $ForceModel" })
} else {
    $channels = $ModelChannels.ImageGen
}

# ── 带容错调用 ──
try {
    $result = Invoke-DmxApiWithFallback `
        -ChannelList $channels `
        -Endpoint "images/generations" `
        -Body $body `
        -TimeoutSec 180

    # ── 确保输出目录存在 ──
    $output_dir = Join-Path (Split-Path -Parent $script_dir) "output"
    if (-not (Test-Path $output_dir)) {
        New-Item -Path $output_dir -ItemType Directory -Force | Out-Null
    }

    $images = @()
    $img_idx = 0
    foreach ($item in $result.Response.data) {
        $img_idx++
        if ($item.url) {
            $images += $item.url
        } elseif ($item.b64_json) {
            # base64 → 保存到 output/
            if ($OutputFile -and $img_idx -eq 1) {
                $img_path = $OutputFile
            } elseif ($OutputFile) {
                $img_path = $OutputFile -replace '\.png$', "_${img_idx}.png"
            } else {
                $img_path = Join-Path $output_dir "lumen_gen_$(Get-Date -Format 'yyyyMMddHHmmss')_${img_idx}.png"
            }
            $bytes = [Convert]::FromBase64String($item.b64_json)
            [System.IO.File]::WriteAllBytes($img_path, $bytes)
            $images += $img_path
        }
    }

    $meta = "[通道: $($result.Channel) | 第$($result.Attempt)次尝试 | 耗时: $($result.ElapsedSec)s | 生成: $($images.Count)张]"

} catch {
    Write-Error "生图失败: 所有 6 个通道均不可用`n$_"
    exit 2
}

# ── 修复 PS 5.1 中文 Windows 编码 ──
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── 智能模式：有 OutputFile 时自动切 both ──
if ($OutputFile -and $Output -eq "stdout") { $Output = "both" }

# ── 输出 ──
$url_output = $images -join "`n"

switch ($Output) {
    "stdout" {
        if (-not $Quiet) { Write-Host $meta -ForegroundColor DarkGray }
        Write-Output $url_output
    }
    "file" {
        if (-not $OutputFile) { Write-Error "Output=file 时必须指定 -OutputFile"; exit 3 }
        $first = $result.Response.data[0]
        if ($first.url) {
            Invoke-WebRequest -Uri $first.url -OutFile $OutputFile -TimeoutSec 60
        }
        if (-not $Quiet) { Write-Host "[✓] 已保存 $OutputFile ($($result.Channel))" -ForegroundColor Green }
    }
    "both" {
        if ($OutputFile) {
            $first = $result.Response.data[0]
            if ($first.url) {
                Invoke-WebRequest -Uri $first.url -OutFile $OutputFile -TimeoutSec 60
            }
        }
        if (-not $Quiet) { Write-Host $meta -ForegroundColor DarkGray }
        Write-Output $url_output
        if ($OutputFile -and -not $Quiet) { Write-Host "[✓] 已保存 $OutputFile" -ForegroundColor Green }
    }
}


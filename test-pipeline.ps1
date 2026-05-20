<#
.SYNOPSIS
    端到端测试——验证 DMXAPI 识图 + 生图管道所有通道
    使用 Invoke-DmxApiWithFallback 链式容错引擎
.DESCRIPTION
    测试覆盖:
      - Key 读取验证
      - ImageGen 6 通道逐通道连通性 (T1 > T2 > T3)
      - Vision 3 通道逐通道连通性 (T1 > T2)
      - 通道耗时统计
    用法:
      .\test-pipeline.ps1
      .\test-pipeline.ps1 -ImagePath "C:\test.png"  # 同时测试真实识图
      .\test-pipeline.ps1 -SkipImageGen              # 跳过生图测试
      .\test-pipeline.ps1 -SkipVision                # 跳过识图测试
.NOTES
    前置条件: 先运行 secure-setup.ps1 存储 image key
    作者: Xi Ewell · Duke Ewell Laboratory
    依赖: dmxapi-auth.ps1（同目录）
#>

param(
    [Parameter(HelpMessage="测试图片路径（用于真实识图测试）")]
    [string]$ImagePath,

    [Parameter(HelpMessage="跳过生图通道测试")]
    [switch]$SkipImageGen,

    [Parameter(HelpMessage="跳过识图通道测试")]
    [switch]$SkipVision
)

$ErrorActionPreference = "Continue"
$script_dir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   DMXAPI 图像管道 端到端测试 (全部通道)      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# ── 加载认证模块 ──
. (Join-Path $script_dir "dmxapi-auth.ps1")

# ── Test 0: Key 可读 ──
Write-Host "── Test 0: Key 读取 ──" -ForegroundColor Yellow
$key = Get-DmxApiKey -KeyType "image"
if ($key) {
    $masked = $key.Substring(0, [Math]::Min(6, $key.Length)) + "..." + $key.Substring($key.Length - 3)
    Write-Host "  [✓] Key 可读: $masked" -ForegroundColor Green
} else {
    Write-Host "  [✗] Key 读取失败——请先运行 secure-setup.ps1" -ForegroundColor Red
    exit 1
}

$results = @{ ImageGen = @(); Vision = @() }

# ═══════════════════════════════════════════════════════
# Test 1: 生图通道逐一测试
# ═══════════════════════════════════════════════════════
if (-not $SkipImageGen) {
    Write-Host "`n── Test 1: ImageGen 通道连通性 (6 通道) ──" -ForegroundColor Yellow
    Write-Host "  测试每个通道基础连通性（非容错链测试）`n" -ForegroundColor DarkGray

    $gen_channels = $ModelChannels.ImageGen

    foreach ($ch in $gen_channels) {
        $label = $ch.Label
        $model = $ch.Model

        Write-Host "  [$label]" -ForegroundColor DarkCyan -NoNewline

        $body = @{
            model  = $model
            prompt = "A simple blue circle on white background, minimal style"
            size   = "1024x1024"
            n      = 1
        } | ConvertTo-Json

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-RestMethod `
                -Uri "$DMXAPI_BASE_URL/images/generations" `
                -Method Post `
                -Headers @{
                    Authorization = "Bearer $key"
                    "Content-Type"  = "application/json"
                } `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -TimeoutSec 120

            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $has_url = $response.data -and $response.data[0].url
            $has_b64 = $response.data -and $response.data[0].b64_json

            if ($has_url -or $has_b64) {
                Write-Host " [✓] ${elapsed}s" -ForegroundColor Green
                $results.ImageGen += @{ Model = $model; Label = $label; Status = "OK"; Time = $elapsed }
            } else {
                Write-Host " [?] ${elapsed}s (格式异常)" -ForegroundColor Yellow
                $results.ImageGen += @{ Model = $model; Label = $label; Status = "FormatError"; Time = $elapsed }
            }
        } catch {
            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $status_code = ""
            if ($_.Exception.Response) {
                $status_code = [int]$_.Exception.Response.StatusCode
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $err_body = $reader.ReadToEnd()
                Write-Host " [✗] HTTP $status_code (${elapsed}s)" -ForegroundColor Red
                Write-Host "        $($err_body.Substring(0, [Math]::Min(120, $err_body.Length)))" -ForegroundColor DarkGray
            } else {
                Write-Host " [✗] ${elapsed}s: $($_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)))" -ForegroundColor Red
            }
            $results.ImageGen += @{ Model = $model; Label = $label; Status = "Fail($status_code)"; Time = $elapsed }
        }
    }
}

# ═══════════════════════════════════════════════════════
# Test 2: 识图通道逐一测试
# ═══════════════════════════════════════════════════════
if (-not $SkipVision) {
    Write-Host "`n── Test 2: Vision 通道连通性 (3 通道) ──" -ForegroundColor Yellow

    $vision_channels = $ModelChannels.Vision

    foreach ($ch in $vision_channels) {
        $label = $ch.Label
        $model = $ch.Model

        Write-Host "  [$label]" -ForegroundColor DarkCyan -NoNewline

        # 不带图片的纯文本测试——只测连通性和模型可用性
        $body = @{
            model    = $model
            messages = @(
                @{
                    role    = "user"
                    content = "Respond with exactly 'OK' and nothing else."
                }
            )
            max_tokens  = 10
            temperature = 0.1
        } | ConvertTo-Json -Depth 4

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-RestMethod `
                -Uri "$DMXAPI_BASE_URL/chat/completions" `
                -Method Post `
                -Headers @{
                    Authorization = "Bearer $key"
                    "Content-Type"  = "application/json"
                } `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                -TimeoutSec 60

            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $content = $response.choices[0].message.content
            Write-Host " [✓] ${elapsed}s" -ForegroundColor Green
            $results.Vision += @{ Model = $model; Label = $label; Status = "OK"; Time = $elapsed }
        } catch {
            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $status_code = ""
            if ($_.Exception.Response) {
                $status_code = [int]$_.Exception.Response.StatusCode
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $err_body = $reader.ReadToEnd()
                Write-Host " [✗] HTTP $status_code (${elapsed}s)" -ForegroundColor Red
                Write-Host "        $($err_body.Substring(0, [Math]::Min(120, $err_body.Length)))" -ForegroundColor DarkGray
            } else {
                Write-Host " [✗] ${elapsed}s: $($_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)))" -ForegroundColor Red
            }
            $results.Vision += @{ Model = $model; Label = $label; Status = "Fail($status_code)"; Time = $elapsed }
        }
    }
}

# ═══════════════════════════════════════════════════════
# Test 3: 真实识图（如果提供了图片）
# ═══════════════════════════════════════════════════════
if ($ImagePath -and (Test-Path $ImagePath)) {
    Write-Host "`n── Test 3: 真实识图 (容错链: $($ModelChannels.Vision.Count) 通道) ──" -ForegroundColor Yellow

    $describe_script = Join-Path $script_dir "describe-image.ps1"
    $result = & $describe_script -ImagePath $ImagePath -Quiet 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [✓] 识图成功" -ForegroundColor Green
        Write-Host "  ── 前 200 字符预览 ──" -ForegroundColor DarkGray
        $preview = ($result -join " ")  # 处理可能的多行输出
        Write-Host $preview.Substring(0, [Math]::Min(200, $preview.Length))
        if ($preview.Length -gt 200) { Write-Host "  ... (共 $($preview.Length) 字符)" -ForegroundColor DarkGray }
    } else {
        Write-Host "  [✗] 识图失败" -ForegroundColor Red
        Write-Host ($result | Select-Object -First 5) -ForegroundColor Red
    }
}

# ═══════════════════════════════════════════════════════
# 汇总
# ═══════════════════════════════════════════════════════
Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   测试汇总                                    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan

if (-not $SkipImageGen) {
    Write-Host "`n  ImageGen 生图通道:" -ForegroundColor White
    $ok_count = ($results.ImageGen | Where-Object { $_.Status -eq "OK" }).Count
    $total_count = $results.ImageGen.Count
    foreach ($r in $results.ImageGen) {
        $color = if ($r.Status -eq "OK") { "Green" } else { "Red" }
        Write-Host "    [$($r.Status)] $($r.Label) — $($r.Time)s" -ForegroundColor $color
    }
    $ig_color = if ($ok_count -gt 0) { "Green" } else { "Red" }
    Write-Host "  ImageGen: $ok_count/$total_count 通道可达" -ForegroundColor $ig_color
}

if (-not $SkipVision) {
    Write-Host "`n  Vision 识图通道:" -ForegroundColor White
    $ok_count = ($results.Vision | Where-Object { $_.Status -eq "OK" }).Count
    $total_count = $results.Vision.Count
    foreach ($r in $results.Vision) {
        $color = if ($r.Status -eq "OK") { "Green" } else { "Red" }
        Write-Host "    [$($r.Status)] $($r.Label) — $($r.Time)s" -ForegroundColor $color
    }
    $vis_color = if ($ok_count -gt 0) { "Green" } else { "Red" }
    Write-Host "  Vision: $ok_count/$total_count 通道可达" -ForegroundColor $vis_color
}

Write-Host "`n下一步:" -ForegroundColor White
Write-Host "  1. DMXAPI 后台确认图像 key 的模型权限已勾选所有 9 个模型" -ForegroundColor DarkGray
Write-Host "  2. 9 模型清单:" -ForegroundColor DarkGray
Write-Host "     ImageGen: gpt-image-2, gpt-image-2-ssvip, gemini-3.1-flash-image-preview, gemini-2.5-flash-image, doubao-seedream-4-5-251128, doubao-seedream-4-0-250828" -ForegroundColor DarkGray
Write-Host "     Vision: Doubao-1.5-vision-pro-32k, gemini-2.5-flash, gemini-2.5-flash-ssvip" -ForegroundColor DarkGray
Write-Host "  3. CherryStudio 中新增 provider (DMXAPI-Image)，填入图像 key" -ForegroundColor DarkGray
Write-Host "  4. CherryStudio 中将默认图像模型设为 gpt-image-2" -ForegroundColor DarkGray


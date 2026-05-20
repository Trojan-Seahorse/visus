<#
.SYNOPSIS
    DMXAPI 认证辅助模块
    从 DPAPI 加密文件中读取 API key
    其他脚本通过 dot-source 引用: . "$PSScriptRoot\dmxapi-auth.ps1"
.NOTES
    作者: Xi Ewell · Duke Ewell Laboratory
#>

function Get-DmxApiKey {
    <#
    .SYNOPSIS
        从加密文件中解密 DMXAPI key
    .PARAMETER KeyType
        "main" = 主 key (DeepSeek V4 Pro 等)
        "image" = 图像专用 key (gpt-image-2 + VLM)
    #>
    param(
        [ValidateSet("main", "image")]
        [string]$KeyType = "image"
    )

    $file = Join-Path "$env:USERPROFILE\.dmxapi" "$KeyType`_key.xml"

    if (-not (Test-Path $file)) {
        Write-Error "Key 文件不存在: $file`n请先运行 secure-setup.ps1 存储 key。"
        return $null
    }

    try {
        # DPAPI 解密——仅当前用户+当前机器可解密
        # PS 5.1 兼容：用 Marshal 而非 -AsPlainText（7.0+）
        $secure = Import-Clixml $file
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $key = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
        if ([string]::IsNullOrEmpty($key)) {
            Write-Error "Key 解密结果为空"
            return $null
        }
        return $key
    } catch [System.Security.Cryptography.CryptographicException] {
        Write-Error "DPAPI 解密失败: Key 文件不是在当前用户/当前机器上加密的。`n如果换了电脑或重装系统，请重新运行 secure-setup.ps1。"
        return $null
    } catch {
        Write-Error "读取 Key 失败: $_"
        return $null
    }
}

# PS 5.1 默认不启 TLS 1.2，强制开启
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 默认 base URL（DMXAPI 通常不变）
$script:DMXAPI_BASE_URL = "https://www.dmxapi.cn/v1"

# ═══════════════════════════════════════════════════════════════
# 多通道容错模型表
# ═══════════════════════════════════════════════════════════════
# 每个功能 = 一个优先级降序列表。同供应商同 tier 的 ssvip 通道是并行备选
# （同模异资源池，应对常规通道限流），下一 tier 是降级备选（应对供应商整体不可用）。

# 设计原则：
#   ImageGen — 按供应商 tier 分级：T1(gpt-image-2) > T2(Gemini) > T3(Seedream)
#   Vision   — 按质量梯度分级：T1(中文原生 32K) > T2(Gemini Flash)
# 定价依据：DMXAPI 折扣体系（2.5折~原价），SSVIP 仅在溢价 ≤2x 且模型为 Tier 1 时保留
# 排除记录：
#   gemini-3.1-flash-image-preview-ssvip — 8-960x 溢价，跳过
#   gemini-2.5-flash-image-ssvip — token 计价冗余，跳过
#   doubao-seedream-5.0-lite — 搜索增强架构，不适合通用 fallback
#   qwen2.5-vl-72b-instruct — 7-10x Doubao 价格，零质量证据

$script:ModelChannels = @{

    # ── 生图通道（6 通道 · 3 供应商 · 3 Tier） ──
    # Tier 1: gpt-image-2 — 行业标杆，文字 99%，ELO 1512，242 点领先
    #   gpt-image-2 (6.8折 ~¥0.30-0.60/张)
    #   gpt-image-2-ssvip (原价 ~¥0.46-0.91/张) — 同模异池，溢价 1.47x，保留
    # Tier 2: Gemini Flash Image — Nano Banana 系列，写实强(9.3)，成本极低
    #   gemini-3.1-flash-image-preview (2.5折 ~¥0.001/张) — 最新 Nano Banana 2
    #   gemini-2.5-flash-image (原价 ~¥0.25/张) — 稳定锚，token 计价
    # Tier 3: Seedream — 豆包系列，中文生态兼容，终极兜底
    #   doubao-seedream-4-5-251128 (原价 ~¥0.25/张) — 4.0 修复版
    #   doubao-seedream-4-0-250828 (7.5折 ~¥0.15/张) — 已知缺陷但可兜底
    ImageGen = @(
        @{ Model = "gpt-image-2";                      Label = "T1 gpt-image-2 (主力)" },
        @{ Model = "gpt-image-2-ssvip";                Label = "T1 gpt-image-2 SSVIP (同模异池)" },
        @{ Model = "gemini-3.1-flash-image-preview";    Label = "T2 Gemini 3.1 Flash Image (Nano Banana 2)" },
        @{ Model = "gemini-2.5-flash-image";            Label = "T2 Gemini 2.5 Flash Image (稳定锚)" },
        @{ Model = "doubao-seedream-4-5-251128";       Label = "T3 Seedream 4.5 (兜底)" },
        @{ Model = "doubao-seedream-4-0-250828";       Label = "T3 Seedream 4.0 (终极兜底)" }
    )

    # ── 识图通道（3 通道 · 2 供应商 · 2 Tier） ──
    # Tier 1: Doubao-1.5-vision-pro-32k — 中文原生 VLM，32K 上下文
    #   (5.0折 ~¥3-5/次) — 中文场景最优，大上下文适合复杂 UI/文档
    # Tier 2: Gemini 2.5 Flash — 已验证兼容，英文强，通用性好
    #   gemini-2.5-flash (6.8折 ~¥3-5/次)
    #   gemini-2.5-flash-ssvip (原价 ~¥4-7/次) — 溢价 1.46x 可接受，保留
    Vision = @(
        @{ Model = "Doubao-1.5-vision-pro-32k"; Label = "T1 Doubao Vision Pro (主力·中文原生)" },
        @{ Model = "gemini-2.5-flash";           Label = "T2 Gemini 2.5 Flash (备选)" },
        @{ Model = "gemini-2.5-flash-ssvip";     Label = "T2 Gemini 2.5 Flash SSVIP (备选2)" }
    )
}

# ═══════════════════════════════════════════════════════════════
# 链式容错引擎
# ═══════════════════════════════════════════════════════════════

function Invoke-DmxApiWithFallback {
    <#
    .SYNOPSIS
        按优先级链式调用 DMXAPI，自动在通道间容错
    .PARAMETER ChannelList
        通道列表（从 $ModelChannels 取值）
    .PARAMETER Endpoint
        API 端点后缀，如 "chat/completions" 或 "images/generations"
    .PARAMETER Body
        请求体 JSON 字符串
    .PARAMETER TimeoutSec
        每个通道的超时秒数（默认 120）
    .PARAMETER ApiKey
        API key（可选，不传则自动从 image key 读取）
    #>
    param(
        [Parameter(Mandatory=$true)]
        [array]$ChannelList,

        [Parameter(Mandatory=$true)]
        [string]$Endpoint,

        [Parameter(Mandatory=$true)]
        [string]$Body,

        [int]$TimeoutSec = 120,

        [string]$ApiKey
    )

    if (-not $ApiKey) {
        $ApiKey = Get-DmxApiKey -KeyType "image"
        if (-not $ApiKey) { throw "无法获取 API key" }
    }

    $total_channels = $ChannelList.Count
    $errors = @()

    for ($i = 0; $i -lt $total_channels; $i++) {
        $ch = $ChannelList[$i]
        $label = $ch.Label
        $model = $ch.Model

        # 注入当前通道的 model ID
        $body_obj = $Body | ConvertFrom-Json
        $body_obj.model = $model
        $body_bytes = [System.Text.Encoding]::UTF8.GetBytes(($body_obj | ConvertTo-Json -Depth 8 -Compress))

        Write-Verbose "[$($i+1)/$total_channels] 尝试: $label ($model)"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-RestMethod `
                -Uri "$DMXAPI_BASE_URL/$Endpoint" `
                -Method Post `
                -Headers @{
                    Authorization = "Bearer $ApiKey"
                    "Content-Type"  = "application/json"
                } `
                -Body $body_bytes `
                -TimeoutSec $TimeoutSec

            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            # 返回结果 + 元数据
            return [PSCustomObject]@{
                Response   = $response
                Channel    = $label
                Model      = $model
                ElapsedSec = $elapsed
                Attempt    = $i + 1
                Success    = $true
            }
        } catch {
            $sw.Stop()
            $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)

            $err_msg = if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                "$label → HTTP $statusCode (${elapsed}s)"
            } else {
                "$label → $($_.Exception.Message) (${elapsed}s)"
            }

            Write-Warning "  [✗] $err_msg"
            $errors += $err_msg

            # 429/503 → 等一等再试下一个通道
            if ($statusCode -eq 429 -or $statusCode -eq 503) {
                $wait = 2 + ($i * 2)
                Write-Verbose "  等待 ${wait}s 后尝试下一通道..."
                Start-Sleep -Seconds $wait
            }
        }
    }

    # 所有通道耗尽
    throw "所有 $total_channels 个通道均调用失败:`n$($errors -join "`n")"
}



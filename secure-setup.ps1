<#
.SYNOPSIS
    DMXAPI Key 安全存储脚本
    使用 Windows DPAPI 加密存储 API key，绑定当前用户+机器
.DESCRIPTION
    零额外依赖，PowerShell 5.1+ 原生可用。
    加密后的文件仅能在当前用户、当前机器上解密。
    文件被拷贝到其他机器/用户后无法解密。
.NOTES
    作者: Xi Ewell · Duke Ewell Laboratory
#>

$ErrorActionPreference = "Stop"

# --- 路径 ---
$storage_dir = "$env:USERPROFILE\.dmxapi"
$image_key_file = Join-Path $storage_dir "image_key.xml"
$main_key_file  = Join-Path $storage_dir "main_key.xml"

# --- 确保目录存在 ---
if (-not (Test-Path $storage_dir)) {
    New-Item -Path $storage_dir -ItemType Directory -Force | Out-Null
    Write-Host "[+] 已创建 $storage_dir" -ForegroundColor Green
}

# --- 辅助函数 ---
function Save-EncryptedKey {
    param([string]$Label, [string]$FilePath)

    Write-Host "`n*** $Label ***" -ForegroundColor Cyan
    Write-Host "粘贴 key (输入不可见，按 Enter 确认):" -ForegroundColor Yellow

    $secure = Read-Host -AsSecureString
    if (-not $secure -or $secure.Length -eq 0) {
        Write-Host "[!] 输入为空，已跳过" -ForegroundColor Red
        return
    }

    $secure | Export-Clixml -Path $FilePath -Force
    Write-Host "[OK] 已加密存储到: $FilePath" -ForegroundColor Green
}

function Show-EncryptedKey {
    param([string]$Label, [string]$FilePath)

    if (Test-Path $FilePath) {
        try {
            $secure = Import-Clixml $FilePath
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try { $key = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
            if ($key) {
                $masked = $key.Substring(0, [Math]::Min(8, $key.Length)) + "..." + $key.Substring($key.Length - 4)
                Write-Host "  $Label : $masked (已存储)" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  $Label : [文件损坏或无法解密]" -ForegroundColor Red
        }
    } else {
        Write-Host "  $Label : [未配置]" -ForegroundColor DarkGray
    }
}

# --- 当前状态 ---
Write-Host "`n=== 当前存储状态 ===" -ForegroundColor Magenta
Show-EncryptedKey "Main Key " $main_key_file
Show-EncryptedKey "Image Key" $image_key_file

# --- 交互菜单 ---
Write-Host "`n=== 选择操作 ===" -ForegroundColor Magenta
Write-Host "  [1] 存储/更新 图像专用 key (gpt-image-2 + VLM)"
Write-Host "  [2] 存储/更新 主 key (DeepSeek V4 Pro 等)"
Write-Host "  [3] 两个都更新"
Write-Host "  [4] 仅查看当前状态 (不做修改)"
Write-Host "  [0] 退出"

$choice = Read-Host "`n输入选项"

switch ($choice) {
    "1" {
        Save-EncryptedKey "图像专用 Key" $image_key_file
    }
    "2" {
        Save-EncryptedKey "主 Key" $main_key_file
    }
    "3" {
        Save-EncryptedKey "图像专用 Key" $image_key_file
        Save-EncryptedKey "主 Key" $main_key_file
    }
    "4" {
        Write-Host "`n不做修改。" -ForegroundColor Gray
    }
    "0" {
        exit 0
    }
    default {
        Write-Host "[!] 无效选项" -ForegroundColor Red
        exit 1
    }
}

Write-Host "`n=== 更新后状态 ===" -ForegroundColor Magenta
Show-EncryptedKey "Main Key " $main_key_file
Show-EncryptedKey "Image Key" $image_key_file

Write-Host "`n[OK] 完成。Key 已加密存储，仅当前用户+当前机器可解密。" -ForegroundColor Green

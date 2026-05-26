# Test script: DMXAPI gpt-image-2 multi-image edit (face replacement)
# Purpose: Verify if DMXAPI /v1/images/edits can replace a person in a group photo

$ErrorActionPreference = "Stop"
$script_dir = "D:\Cherry Studio\scripts"
. "$script_dir\dmxapi-auth.ps1"

$apiKey = Get-DmxApiKey -KeyType "image"
if (-not $apiKey) { Write-Error "Failed to get API key"; exit 1 }

$groupImg = 'C:\Users\Duke-\Pictures\改图\微信图片_20260525185411_180_20.jpg'
$soloImg  = 'C:\Users\Duke-\Pictures\改图\微信图片_20260525190212_185_20.jpg'

Write-Host "[1/4] Reading images..." -ForegroundColor Cyan
$groupBytes = [System.IO.File]::ReadAllBytes($groupImg)
$soloBytes  = [System.IO.File]::ReadAllBytes($soloImg)
Write-Host "  合照: $($groupBytes.Count) bytes"
Write-Host "  单人: $($soloBytes.Count) bytes"

Write-Host "[2/4] Building multipart request..." -ForegroundColor Cyan

$boundary = "----DMXAPI-Boundary-$(Get-Date -Format 'yyyyMMddHHmmss')"
$LF = "`r`n"
$enc = [System.Text.Encoding]::UTF8

# Build multipart form body as byte array
$ms = New-Object System.IO.MemoryStream

function Write-BoundaryLine($text) {
    $bytes = $enc.GetBytes($text + $LF)
    $script:ms.Write($bytes, 0, $bytes.Length)
}
function Write-Boundary {
    Write-BoundaryLine "--$boundary"
}
function Write-BoundaryEnd {
    Write-BoundaryLine "--$boundary--"
}
function Write-FormField($name, $value) {
    Write-Boundary
    Write-BoundaryLine "Content-Disposition: form-data; name=`"$name`""
    Write-BoundaryLine ""
    Write-BoundaryLine $value
}
function Write-FileField($name, $filename, $bytes, $mimeType) {
    Write-Boundary
    Write-BoundaryLine "Content-Disposition: form-data; name=`"$name`"; filename=`"$filename`""
    Write-BoundaryLine "Content-Type: $mimeType"
    Write-BoundaryLine ""
    $script:ms.Write($bytes, 0, $bytes.Length)
    Write-BoundaryLine ""
}

# Fields
Write-FormField "model" "gpt-image-2-ssvip"
Write-FormField "prompt" "Replace the woman on the far left (wearing a white shawl and black dress) with the woman in the second reference image. Keep the name badge and lanyard on the original woman's chest exactly as they are. The other three people and the exhibition booth background (CABOT signage) must remain completely unchanged. Make the replacement look natural with matching lighting and skin tone."
Write-FormField "size" "1024x1024"
Write-FormField "n" "1"
Write-FileField "image" "group.jpg" $groupBytes "image/jpeg"
Write-FileField "image" "solo.jpg" $soloBytes "image/jpeg"
Write-BoundaryEnd

$bodyBytes = $ms.ToArray()
$ms.Dispose()
Write-Host "  Total body size: $($bodyBytes.Count) bytes"

Write-Host "[3/4] Sending to DMXAPI /v1/images/edits..." -ForegroundColor Cyan
Write-Host "  Model: gpt-image-2-ssvip"

try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod `
        -Uri "https://www.dmxapi.cn/v1/images/edits" `
        -Method Post `
        -Headers @{
            Authorization = "Bearer $apiKey"
            "Content-Type" = "multipart/form-data; boundary=$boundary"
        } `
        -Body $bodyBytes `
        -TimeoutSec 120
    $sw.Stop()

    Write-Host "[4/4] Response received in $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Green

    # Check response
    if ($response.data -and $response.data.Count -gt 0) {
        $img = $response.data[0]
        Write-Host "  Response keys: $($response | ConvertTo-Json -Depth 1)"

        if ($img.url) {
            Write-Host "  Image URL: $($img.url)" -ForegroundColor Green
        } elseif ($img.b64_json) {
            $outPath = "D:\Cherry Studio\output\lumen_edit_$(Get-Date -Format 'yyyyMMddHHmmss').png"
            $outDir = Split-Path $outPath -Parent
            if (-not (Test-Path $outDir)) { New-Item -Path $outDir -ItemType Directory -Force | Out-Null }
            [System.IO.File]::WriteAllBytes($outPath, [Convert]::FromBase64String($img.b64_json))
            Write-Host "  Image saved to: $outPath" -ForegroundColor Green
            Write-Host "  Base64 length: $($img.b64_json.Length) chars" -ForegroundColor Green
        }
    } else {
        Write-Host "  Unexpected response structure:" -ForegroundColor Yellow
        Write-Host ($response | ConvertTo-Json -Depth 3)
    }
} catch {
    $sw.Stop()
    Write-Host "[FAIL] Request failed after $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor Red

    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errorBody = $reader.ReadToEnd()
        $reader.Dispose()
        Write-Host "  HTTP $statusCode" -ForegroundColor Red
        Write-Host "  Body: $errorBody" -ForegroundColor Red
    } else {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

<#
.SYNOPSIS
    Launch GitHub Copilot CLI with Foundry Local (Phi-4) as the backend.
.DESCRIPTION
    Starts a model-name rewrite proxy (foundry-proxy.cjs), then launches
    Copilot CLI pointed at the proxy using BYOK mode. The proxy rewrites
    "gpt-4.1" to Foundry's internal model ID (e.g. Phi-4-generic-cpu:1).
    Temporarily hides MCP configs to stay under the 128-tool limit.
    Restores everything on exit (Ctrl+C safe via try/finally).
.PARAMETER Model
    The model name to pass to Copilot CLI. Default: gpt-4.1
.PARAMETER ProxyPort
    Port for the rewrite proxy. Default: 5272
.EXAMPLE
    .\launch-foundry.ps1
    .\launch-foundry.ps1 --yolo
    .\launch-foundry.ps1 -ProxyPort 5280
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Model     = 'gpt-4.1',
    [int]   $ProxyPort = 5272,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArgs
)

$ErrorActionPreference = 'Stop'

# --- Auto-discover Foundry port ---
$foundryPort = $null
try {
    $status = foundry service status 2>&1 | Out-String
    if ($status -match 'http://127\.0\.0\.1:(\d+)/') {
        $foundryPort = $Matches[1]
    }
} catch {}

if (-not $foundryPort) {
    Write-Warning "Could not detect Foundry Local port. Is Foundry running? ('foundry service start')"
    Write-Warning "Falling back to default port 49296."
    $foundryPort = '49296'
}

$env:FOUNDRY_PORT    = $foundryPort
$env:PROXY_PORT      = $ProxyPort
$env:COPILOT_PROVIDER_BASE_URL = "http://localhost:$ProxyPort/v1"
$env:COPILOT_PROVIDER_API_KEY  = 'foundry-local'

# --- Verify 'copilot' command is available ---
$copilotCmd = Get-Command 'copilot' -ErrorAction SilentlyContinue
if (-not $copilotCmd) {
    Write-Error "'copilot' command not found. Install the Copilot CLI (see README) and ensure it is on your PATH."
    exit 1
}

# --- Locate the proxy script ---
$proxyScript = Join-Path $PSScriptRoot 'foundry-proxy.cjs'
if (-not (Test-Path $proxyScript)) {
    Write-Error "foundry-proxy.cjs not found next to this script. Expected at: $proxyScript"
    exit 1
}

# --- Start the model-name rewrite proxy ---
Write-Host ""
Write-Host "Starting Foundry proxy (localhost:$ProxyPort -> Foundry on :$foundryPort)..." -ForegroundColor Cyan
$proxyJob = Start-Job -ScriptBlock {
    param($script, $fPort, $pPort)
    $env:FOUNDRY_PORT = $fPort
    $env:PROXY_PORT   = $pPort
    node $script 2>&1
} -ArgumentList $proxyScript, $foundryPort, $ProxyPort
Start-Sleep -Seconds 2

# --- Temporarily hide MCP configs (128-tool limit) ---
$mcpFiles = @(
    (Join-Path $env:USERPROFILE '.copilot' 'mcp-config.json'),
    (Join-Path (Get-Location) '.copilot' 'mcp-config.json')
)
$moved = @()
foreach ($f in $mcpFiles) {
    if (Test-Path $f) {
        $bak = "$f.local-bak"
        Move-Item $f $bak -Force
        $moved += @{ orig = $f; bak = $bak }
        Write-Host "  Hid $f" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Copilot CLI + Foundry Local (Phi-4)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Command:  copilot" -ForegroundColor DarkGray
Write-Host "  Model:    $Model -> Phi-4 (via proxy)" -ForegroundColor DarkGray
Write-Host "  Proxy:    http://localhost:$ProxyPort -> Foundry :$foundryPort" -ForegroundColor DarkGray
Write-Host "  Mode:     COPILOT_PROVIDER_BASE_URL (BYOK)" -ForegroundColor DarkGray
Write-Host ""

try {
    $extraArgs = $CopilotArgs
    if ($extraArgs.Count -gt 0) {
        copilot @extraArgs --model $Model
    } else {
        copilot --model $Model
    }
} finally {
    # Restore MCP configs
    foreach ($m in $moved) {
        if (Test-Path $m.bak) {
            Move-Item $m.bak $m.orig -Force
            Write-Host "  Restored $($m.orig)" -ForegroundColor DarkGray
        }
    }
    # Stop proxy
    Stop-Job $proxyJob -ErrorAction SilentlyContinue
    Remove-Job $proxyJob -Force -ErrorAction SilentlyContinue
    Write-Host "  Proxy stopped." -ForegroundColor DarkGray

}

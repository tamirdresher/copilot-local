<#
.SYNOPSIS
    Launch GitHub Copilot CLI in hybrid mode (cloud + local models).
.DESCRIPTION
    Starts the hybrid proxy that routes model requests to different backends
    based on model name. Cloud models (Claude, GPT-5) go to GitHub API,
    local models (gpt-4.1, gpt-5-mini) go to Ollama/Foundry.
    Does NOT hide MCP configs — cloud models handle full tool count.
.PARAMETER Model
    The default model for Copilot CLI. Default: claude-sonnet-4.5
.PARAMETER ProxyPort
    Port for the hybrid proxy. Default: 9090
.PARAMETER Config
    Path to hybrid-proxy.config.json. Default: next to this script.
.EXAMPLE
    .\launch-hybrid.ps1
    .\launch-hybrid.ps1 --model claude-sonnet-4.5
    .\launch-hybrid.ps1 -Model gpt-4.1
#>
param(
    [string]$Model     = 'claude-sonnet-4.5',
    [int]   $ProxyPort = 9090,
    [string]$Config    = ''
)

$ErrorActionPreference = 'Stop'

# --- Locate config ---
if (-not $Config) {
    $Config = Join-Path $PSScriptRoot 'hybrid-proxy.config.json'
}
if (-not (Test-Path $Config)) {
    Write-Error "Config not found: $Config"
    exit 1
}

# --- Locate proxy script ---
$proxyScript = Join-Path $PSScriptRoot 'hybrid-proxy.cjs'
if (-not (Test-Path $proxyScript)) {
    Write-Error "hybrid-proxy.cjs not found next to this script. Expected at: $proxyScript"
    exit 1
}

# --- Auto-discover Copilot CLI binary ---
$copilotDir = Join-Path $env:USERPROFILE '.copilot' 'pkg' 'tmp'
if (-not (Test-Path $copilotDir)) {
    Write-Error "Copilot CLI not found at $copilotDir. Run 'gh copilot' first to install it."
    exit 1
}

$binary = Get-ChildItem $copilotDir -Filter 'index.js' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName

if (-not $binary) {
    Write-Error "Copilot CLI binary (index.js) not found under $copilotDir. Run 'gh copilot' first."
    exit 1
}

# --- Set environment for Copilot CLI ---
$env:OPENAI_BASE_URL = "http://localhost:$ProxyPort/v1"
$env:OPENAI_API_KEY  = 'hybrid-proxy'

# --- Start the hybrid proxy ---
Write-Host ""
Write-Host "Starting hybrid proxy on localhost:$ProxyPort..." -ForegroundColor Cyan
$proxyJob = Start-Job -ScriptBlock {
    param($script, $configPath)
    node $script --config $configPath 2>&1
} -ArgumentList $proxyScript, $Config
Start-Sleep -Seconds 2

# Verify proxy started
$proxyState = Get-Job $proxyJob.Id
if ($proxyState.State -eq 'Failed') {
    Write-Error "Hybrid proxy failed to start. Check the config at: $Config"
    Receive-Job $proxyJob
    exit 1
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Copilot CLI — Hybrid Mode" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Binary:  $binary" -ForegroundColor DarkGray
Write-Host "  Model:   $Model" -ForegroundColor DarkGray
Write-Host "  Proxy:   http://localhost:$ProxyPort" -ForegroundColor DarkGray
Write-Host "  Config:  $Config" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Cloud models (claude-*, gpt-5*) → GitHub API" -ForegroundColor DarkCyan
Write-Host "  Local models (gpt-4.1, etc.)    → Ollama/Foundry" -ForegroundColor DarkCyan
Write-Host ""

try {
    $extraArgs = $args
    if ($extraArgs.Count -gt 0) {
        node $binary @extraArgs --model $Model
    } else {
        node $binary --model $Model
    }
} finally {
    # Stop proxy
    Stop-Job $proxyJob -ErrorAction SilentlyContinue
    Remove-Job $proxyJob -Force -ErrorAction SilentlyContinue
    Write-Host "  Proxy stopped." -ForegroundColor DarkGray

    # Restore env vars
    Remove-Item Env:\OPENAI_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:\OPENAI_API_KEY -ErrorAction SilentlyContinue
    Write-Host "  Environment restored." -ForegroundColor DarkGray
}

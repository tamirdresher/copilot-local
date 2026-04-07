<#
.SYNOPSIS
    Launch GitHub Copilot CLI in hybrid mode (cloud + local models).
.DESCRIPTION
    Starts the hybrid proxy that routes model requests to different backends
    based on model name, as configured in hybrid-proxy.config.json.
    Backends can include cloud (GitHub API), Ollama, LM Studio, or Foundry.
    Hides MCP configs during session to avoid tool-limit issues with local models.
    Uses 'copilot' command (not 'gh copilot' or 'node' directly).
.PARAMETER Model
    The default model for Copilot CLI. Default: claude-sonnet-4.5
.PARAMETER ProxyPort
    Port for the hybrid proxy. Default: 9090
.PARAMETER Config
    Path to hybrid-proxy.config.json. Default: next to this script.
.EXAMPLE
    .\launch-hybrid.ps1
    .\launch-hybrid.ps1 -Model claude-sonnet-4.5
    .\launch-hybrid.ps1 -Model gpt-4.1
    .\launch-hybrid.ps1 -Config .\hybrid-proxy-lmstudio.config.json
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Model     = 'claude-sonnet-4.5',
    [int]   $ProxyPort = 9090,
    [string]$Config    = '',
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArgs
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

# --- Verify 'copilot' command is available ---
$copilotCmd = Get-Command 'copilot' -ErrorAction SilentlyContinue
if (-not $copilotCmd) {
    Write-Error "'copilot' command not found. Install the Copilot CLI: npm install -g @githubnext/github-copilot-cli or ensure it is on your PATH."
    exit 1
}

# --- Read config to detect backends ---
$configData = Get-Content $Config -Raw | ConvertFrom-Json
$backends = @{}
foreach ($prop in $configData.backends.PSObject.Properties) {
    $backends[$prop.Name] = $prop.Value
}

# --- Verify local backends are running ---
if ($backends.ContainsKey('ollama')) {
    try {
        $null = Invoke-RestMethod 'http://localhost:11434/api/version' -TimeoutSec 3
    } catch {
        Write-Warning "Ollama doesn't seem to be running on port 11434. Start it with 'ollama serve'."
    }
}
if ($backends.ContainsKey('lmstudio')) {
    $lmPort = ([uri]$backends['lmstudio'].url).Port
    try {
        $null = Invoke-RestMethod "http://localhost:$lmPort/v1/models" -TimeoutSec 3
    } catch {
        Write-Warning "LM Studio doesn't seem to be running on port $lmPort."
        Write-Warning "Open LM Studio, load a model, and start the local server."
    }
}

# --- Set environment for Copilot CLI (BYOK mode) ---
$env:COPILOT_PROVIDER_BASE_URL = "http://localhost:$ProxyPort/v1"
$env:COPILOT_PROVIDER_API_KEY  = 'hybrid-proxy'

# --- Temporarily hide MCP configs (tool-limit safety) ---
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
Write-Host "  Command: copilot" -ForegroundColor DarkGray
Write-Host "  Model:   $Model" -ForegroundColor DarkGray
Write-Host "  Proxy:   http://localhost:$ProxyPort" -ForegroundColor DarkGray
Write-Host "  Config:  $Config" -ForegroundColor DarkGray
Write-Host "  Mode:    COPILOT_PROVIDER_BASE_URL (BYOK)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Routes:" -ForegroundColor DarkCyan
foreach ($route in $configData.routes) {
    $target = $route.backend
    if ($route.rewriteModel) { $target += " ($($route.rewriteModel))" }
    Write-Host "    $($route.match) → $target" -ForegroundColor DarkCyan
}
Write-Host "    * (default) → $($configData.defaultBackend)" -ForegroundColor DarkCyan
Write-Host ""

try {
    if ($CopilotArgs.Count -gt 0) {
        copilot @CopilotArgs --model $Model
    } else {
        copilot --model $Model
    }
} finally {
    # Stop proxy
    Stop-Job $proxyJob -ErrorAction SilentlyContinue
    Remove-Job $proxyJob -Force -ErrorAction SilentlyContinue
    Write-Host "  Proxy stopped." -ForegroundColor DarkGray

    # Restore MCP configs
    foreach ($m in $moved) {
        if (Test-Path $m.bak) {
            Move-Item $m.bak $m.orig -Force
            Write-Host "  Restored $($m.orig)" -ForegroundColor DarkGray
        }
    }

    Write-Host "  Environment restored." -ForegroundColor DarkGray
}

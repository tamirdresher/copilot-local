<#
.SYNOPSIS
    Launch GitHub Copilot CLI with LM Studio as the backend.
.DESCRIPTION
    Redirects Copilot CLI to a local LM Studio server using BYOK (Bring Your
    Own Key) mode. LM Studio accepts any model name and routes to the currently
    loaded model.
    Temporarily hides MCP configs to stay under the 128-tool limit.
    Restores everything on exit (Ctrl+C safe via try/finally).
.PARAMETER Model
    The model name to pass to Copilot CLI. Default: gpt-4.1
.PARAMETER LMStudioPort
    Port LM Studio is listening on. Default: 1234
.EXAMPLE
    .\launch-lmstudio.ps1
    .\launch-lmstudio.ps1 --yolo
    .\launch-lmstudio.ps1 -LMStudioPort 1234
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Model        = 'gpt-4.1',
    [int]   $LMStudioPort = 1234,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArgs
)

$ErrorActionPreference = 'Stop'

# --- Point Copilot CLI at LM Studio (BYOK mode) ---
$env:COPILOT_PROVIDER_BASE_URL = "http://localhost:$LMStudioPort/v1"
$env:COPILOT_PROVIDER_API_KEY  = 'lm-studio'

# --- Verify 'copilot' command is available ---
$copilotCmd = Get-Command 'copilot' -ErrorAction SilentlyContinue
if (-not $copilotCmd) {
    Write-Error "'copilot' command not found. Install the Copilot CLI (see README) and ensure it is on your PATH."
    exit 1
}

# --- Verify LM Studio is running and has a model loaded ---
$loadedModel = $null
try {
    $models = Invoke-RestMethod "http://localhost:$LMStudioPort/v1/models" -TimeoutSec 3
    if ($models.data.Count -gt 0) {
        $loadedModel = $models.data[0].id
    } else {
        Write-Warning "LM Studio is running but no models are loaded. Load a model first."
    }
} catch {
    Write-Warning "LM Studio doesn't seem to be running on port $LMStudioPort."
    Write-Warning "Open LM Studio, load a model, and start the local server."
}

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
Write-Host " Copilot CLI + LM Studio (BYOK Mode)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Command:  copilot" -ForegroundColor DarkGray
Write-Host "  Model:    $Model -> LM Studio" -ForegroundColor DarkGray
if ($loadedModel) {
    Write-Host "  Loaded:   $loadedModel" -ForegroundColor DarkGray
}
Write-Host "  Endpoint: http://localhost:$LMStudioPort/v1" -ForegroundColor DarkGray
Write-Host "  Mode:     COPILOT_PROVIDER_BASE_URL (BYOK)" -ForegroundColor DarkGray
Write-Host ""

try {
    if ($CopilotArgs.Count -gt 0) {
        copilot @CopilotArgs --model $Model
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
}

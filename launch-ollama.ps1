<#
.SYNOPSIS
    Launch GitHub Copilot CLI with Ollama (Gemma) as the backend.
.DESCRIPTION
    Redirects Copilot CLI to a local Ollama server running on localhost:11434
    using BYOK (Bring Your Own Key) mode.
    Temporarily hides MCP configs to stay under the 128-tool limit.
    Restores everything on exit (Ctrl+C safe via try/finally).
.PARAMETER Model
    The model name to pass to Copilot CLI. Default: gpt-4.1
    (Must match an Ollama alias — run `ollama cp gemma4:e2b gpt-4.1` first)
.EXAMPLE
    .\launch-ollama.ps1
    .\launch-ollama.ps1 --yolo
    .\launch-ollama.ps1 -Model gpt-4.1 --verbose
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Model = 'gpt-4.1',
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$CopilotArgs
)

$ErrorActionPreference = 'Stop'

# --- Point Copilot CLI at Ollama (BYOK mode) ---
$env:COPILOT_PROVIDER_BASE_URL = 'http://localhost:11434/v1'
$env:COPILOT_PROVIDER_API_KEY  = 'ollama'

# --- Verify 'copilot' command is available ---
$copilotCmd = Get-Command 'copilot' -ErrorAction SilentlyContinue
if (-not $copilotCmd) {
    Write-Error "'copilot' command not found. Install the Copilot CLI (see README) and ensure it is on your PATH."
    exit 1
}

# --- Verify Ollama is running ---
try {
    $null = Invoke-RestMethod 'http://localhost:11434/api/version' -TimeoutSec 3
} catch {
    Write-Warning "Ollama doesn't seem to be running on port 11434. Start it with 'ollama serve'."
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
Write-Host " Copilot CLI + Ollama (Local Mode)" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Command:  copilot" -ForegroundColor DarkGray
Write-Host "  Model:    $Model -> Ollama alias" -ForegroundColor DarkGray
Write-Host "  Endpoint: http://localhost:11434/v1" -ForegroundColor DarkGray
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

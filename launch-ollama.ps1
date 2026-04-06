<#
.SYNOPSIS
    Launch GitHub Copilot CLI with Ollama (Gemma) as the backend.
.DESCRIPTION
    Redirects Copilot CLI to a local Ollama server running on localhost:11434.
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
param(
    [string]$Model = 'gpt-4.1'
)

$ErrorActionPreference = 'Stop'

# --- Point Copilot CLI at Ollama ---
$env:OPENAI_BASE_URL = 'http://localhost:11434/v1'
$env:OPENAI_API_KEY  = 'ollama'

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
Write-Host "  Binary:   $binary" -ForegroundColor DarkGray
Write-Host "  Model:    $Model -> Ollama alias" -ForegroundColor DarkGray
Write-Host "  Endpoint: http://localhost:11434/v1" -ForegroundColor DarkGray
Write-Host ""

try {
    # Pass all extra args (e.g., --yolo, --resume, --agent)
    $extraArgs = $args
    if ($extraArgs.Count -gt 0) {
        node $binary @extraArgs --model $Model
    } else {
        node $binary --model $Model
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

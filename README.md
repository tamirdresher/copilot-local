# Copilot Local 🛫

Run the GitHub Copilot CLI with **local models** — no internet, no API keys, no auth required. True airplane mode.

## What This Does

Redirects the GitHub Copilot CLI's model calls to a local inference server ([Ollama](https://ollama.com), [Foundry Local](https://github.com/microsoft/foundry-local), or [LM Studio](https://lmstudio.ai)) running on your machine. You get the full Copilot CLI TUI experience powered by models running entirely on your hardware.

| Mode | Backend | Model | Script | Status |
|------|---------|-------|--------|--------|
| Local only | Ollama | Gemma 4 E2B | `launch-ollama.ps1` | ✅ Tested |
| Local only | Foundry Local | Phi-4 | `launch-foundry.ps1` | ✅ Tested |
| Local only | LM Studio | Qwen 3.5 35B-A3B | `launch-lmstudio.ps1` | ✅ Tested |
| **Hybrid** | Cloud + Local | Opus→Gemma, Sonnet→Cloud | `launch-hybrid.ps1` | ✅ Tested |

## How It Works

The Copilot CLI (`copilot` command) uses the OpenAI chat/completions API internally. We exploit three things:

1. **`COPILOT_PROVIDER_BASE_URL`** — The binary reads this env var and sends requests there instead of GitHub's API (BYOK mode)
2. **`--model gpt-4.1`** — We use a whitelisted model name to pass the CLI's validation
3. **Model aliasing** — We map `gpt-4.1` to the actual local model name

The binary thinks it's talking to GPT-4.1, but the requests actually go to your local server running Gemma/Phi/Qwen.

```
Copilot CLI → "gpt-4.1" → COPILOT_PROVIDER_BASE_URL → localhost → Ollama/Foundry/LM Studio → local model responds
```

### MCP Tool Limit

The Copilot CLI sends all configured tools (MCP servers, plugins, skills, agents) to the model. Local models typically have a 128-tool limit. If you have many MCP servers configured, the scripts temporarily hide the MCP config files and restore them when you exit.

---

## Option 1: Ollama + Gemma 4

### Prerequisites

- [Ollama](https://ollama.com) installed
- GitHub Copilot CLI installed — the `copilot` command must be on your PATH (install via `npm install -g @anthropic-ai/claude-code` or your organization's preferred method)
- Node.js (for proxy scripts)

### Setup

```powershell
# Install Ollama and pull Gemma
winget install Ollama.Ollama   # or download from ollama.com
ollama pull gemma4:e2b          # 7.2 GB download

# Create a model alias so Ollama responds to "gpt-4.1"
ollama cp gemma4:e2b gpt-4.1
```

### Run

```powershell
.\launch-ollama.ps1
# Or with flags:
.\launch-ollama.ps1 --yolo
```

---

## Option 2: Foundry Local + Phi-4

### Prerequisites

- [Foundry Local](https://github.com/microsoft/foundry-local) installed
- GitHub Copilot CLI installed — `copilot` command on your PATH (see Ollama prerequisites above)
- Node.js (for proxy scripts)

### Setup

```powershell
# Install Foundry Local
winget install Microsoft.FoundryLocal   # or from GitHub releases

# Download Phi-4 (happens automatically on first run, ~10 GB)
foundry model run phi-4
```

### Run

```powershell
.\launch-foundry.ps1
# Or with flags:
.\launch-foundry.ps1 --yolo
```

The Foundry script starts a tiny proxy server (`foundry-proxy.cjs`) that rewrites the model name from `gpt-4.1` to Foundry's internal ID (`Phi-4-generic-cpu:1`). The proxy auto-starts and auto-stops with the script.

---

## Option 3: LM Studio

### Prerequisites

- [LM Studio](https://lmstudio.ai) installed
- A model loaded in LM Studio with the local server running (default port 1234)
- GitHub Copilot CLI installed — `copilot` command on your PATH (see Ollama prerequisites above)
- Node.js (for proxy scripts)

### Setup

```powershell
# 1. Download and install LM Studio from https://lmstudio.ai

# 2. Open LM Studio, search for and download a model (e.g., Qwen 3.5 35B-A3B)

# 3. Load the model and start the local server
#    In LM Studio: Developer tab → Start Server (default port 1234)
```

### Run

```powershell
.\launch-lmstudio.ps1
# Or with flags:
.\launch-lmstudio.ps1 --yolo
.\launch-lmstudio.ps1 -LMStudioPort 1234
```

The LM Studio script points directly at LM Studio's OpenAI-compatible API — no proxy needed. LM Studio accepts any model name and routes to the currently loaded model.

### Using Other Models

Load any model in LM Studio — it accepts any model name and routes to the loaded model. No aliasing or configuration needed. Just load a different model and re-run the script.

---

## Option 4: Hybrid Mode (Cloud + Local)

Run cloud models (Claude Sonnet, GPT-5) alongside local models (Gemma via Ollama) in the **same session**. The hybrid proxy inspects each request's model name and routes it to the right backend.

> **Tested and confirmed:** Opus routes to local Gemma, Sonnet routes to cloud. The proxy runs via `copilot` command (not `gh copilot`).

### How It Works

```
Copilot CLI → hybrid-proxy (localhost:9090) → inspects model name
  ├─ claude-opus-4.6   → Ollama (local Gemma, rewritten to gpt-4.1)
  ├─ claude-opus-4.5   → Ollama (local Gemma, rewritten to gpt-4.1)
  ├─ claude-*          → GitHub cloud API (with your auth)
  ├─ gpt-5*            → GitHub cloud API
  ├─ gpt-4.1           → Ollama (local Gemma)
  └─ gpt-5-mini        → Ollama (local Gemma)
```

### Prerequisites

- [Ollama](https://ollama.com) installed and running (`ollama serve`)
- Gemma model pulled and aliased:
  ```powershell
  ollama pull gemma4:e2b
  ollama cp gemma4:e2b gpt-4.1
  ```
- `copilot` command available on PATH (install via `npm install -g @anthropic-ai/claude-code` or your organization's preferred method)
- Node.js (for the hybrid proxy server)

### Setup

1. Ensure Ollama is running with the `gpt-4.1` alias created (see Prerequisites)
2. Run:

```powershell
.\launch-hybrid.ps1
# Or specify default model:
.\launch-hybrid.ps1 -Model claude-sonnet-4.5
```

The script will:
- Start the hybrid proxy on port 9090
- Temporarily hide MCP configs (restored on exit)
- Set `COPILOT_PROVIDER_BASE_URL=http://localhost:9090/v1`
- Launch `copilot --model <Model>`

### Configuration

Edit `hybrid-proxy.config.json` to customize routing:

```json
{
  "listenPort": 9090,
  "backends": {
    "cloud": { "url": "https://api.githubcopilot.com", "auth": "passthrough" },
    "ollama": { "url": "http://localhost:11434", "auth": "static", "apiKey": "ollama" }
  },
  "routes": [
    { "match": "claude-opus-4.6", "backend": "ollama", "rewriteModel": "gpt-4.1" },
    { "match": "claude-opus-4.5", "backend": "ollama", "rewriteModel": "gpt-4.1" },
    { "match": "claude-*", "backend": "cloud" },
    { "match": "gpt-5*", "backend": "cloud" },
    { "match": "gpt-4.1", "backend": "ollama", "rewriteModel": "gpt-4.1" },
    { "match": "gpt-5-mini", "backend": "ollama", "rewriteModel": "gpt-4.1" }
  ],
  "defaultBackend": "cloud"
}
```

**To use LM Studio in hybrid mode**, use the included `hybrid-proxy-lmstudio.config.json` or create your own. LM Studio accepts any model name and routes to the currently loaded model, so `rewriteModel` can be any value — but using the actual model ID (from `http://localhost:1234/v1/models`) is recommended for clarity:

```powershell
.\launch-hybrid.ps1 -Config .\hybrid-proxy-lmstudio.config.json
```

The LM Studio config (`hybrid-proxy-lmstudio.config.json`) looks like:

```json
{
  "listenPort": 9090,
  "backends": {
    "cloud": { "url": "https://api.githubcopilot.com", "auth": "passthrough" },
    "lmstudio": { "url": "http://localhost:1234", "auth": "static", "apiKey": "lm-studio" }
  },
  "routes": [
    { "match": "claude-opus-4.6", "backend": "lmstudio", "rewriteModel": "qwen/qwen3.5-35b-a3b" },
    { "match": "claude-*", "backend": "cloud" },
    { "match": "gpt-5*", "backend": "cloud" },
    { "match": "gpt-4.1", "backend": "lmstudio", "rewriteModel": "qwen/qwen3.5-35b-a3b" }
  ],
  "defaultBackend": "cloud"
}
```

### Use with Squad

Set per-agent model overrides in `.squad/config.json`:

```json
{
  "agentModelOverrides": {
    "data": "gpt-4.1",
    "picard": "claude-opus-4.6",
    "seven": "claude-sonnet-4.5",
    "scribe": "gpt-5-mini"
  }
}
```

This gives you Picard on cloud Opus, Data on local Gemma, and Scribe on local Phi — all in one session.

### Available Model Slots

The Copilot CLI has a hardcoded whitelist. You can repurpose these names for local models:

| Whitelisted Name | Default Route | Can Repurpose? |
|---|---|---|
| `gpt-4.1` | Local (Ollama) | ✅ Best candidate |
| `gpt-5-mini` | Local (Foundry) | ✅ Good candidate |
| `gemini-3-pro-preview` | Local (Foundry) | ✅ Available |
| `gpt-5.1-codex-mini` | Cloud | 🟡 If not using |
| All `claude-*` | Cloud | ❌ Keep for cloud |
| All `gpt-5*` (except mini) | Cloud | ❌ Keep for cloud |

---

## Using Other Models

### Ollama (any model)

```powershell
# Pull any model
ollama pull llama3.3:70b

# Create the alias
ollama cp llama3.3:70b gpt-4.1

# Run
.\launch-ollama.ps1
```

### Foundry Local (other models)

Edit the `MODEL_MAP` in `foundry-proxy.cjs` to add your model's Foundry ID:

```javascript
const MODEL_MAP = {
  'gpt-4.1': 'YOUR-MODEL-ID-HERE',
};
```

Find model IDs with `foundry model list`.

### LM Studio (any model)

No configuration needed — LM Studio accepts any model name and routes to the loaded model:

```powershell
# 1. In LM Studio, load any model
# 2. Start the local server (Developer tab → Start Server)
# 3. Run
.\launch-lmstudio.ps1
```

---

## How to Verify It's Actually Local

1. **Disconnect from the internet** — it still works ✅
2. **Check the API key** — it's set to `'ollama'`, `'foundry-local'`, or `'lm-studio'` (fake keys via `COPILOT_PROVIDER_API_KEY`)
3. **Ask "what model are you?"** — Gemma/Phi/Qwen may identify themselves
4. **Stop the local server** — Copilot CLI immediately fails

---

## Limitations

- **Speed**: Local CPU inference is 10-50x slower than cloud. GPU helps significantly.
- **Tool calling**: Some local models have limited tool calling support. MCP tools may not work.
- **128 tool limit**: MCP configs are temporarily hidden. Your cloud Copilot session is unaffected.
- **Model quality**: Local 7-14B models are less capable than Claude/GPT for complex coding tasks.
- **Windows only**: Scripts are PowerShell. Linux/macOS adaptation is straightforward (PRs welcome!).

---

## Architecture

```
┌─────────────┐     ┌────────────────────────┐     ┌─────────────────┐
│ Copilot CLI  │────▶│  COPILOT_PROVIDER_     │────▶│  Local Server   │
│ (TUI)        │     │  BASE_URL              │     │  Ollama/Foundry │
│ --model      │     │  localhost:11434        │     │  /LM Studio     │
│  gpt-4.1     │     │  or :5272 proxy        │     │  Gemma/Phi/Qwen │
│              │     │  or :1234              │     │                 │
│              │     └────────────────────────┘     └─────────────────┘
└─────────────┘            ▲
                           │ (Foundry only)
                    ┌──────┴───────┐
                    │foundry-proxy │
                    │ Rewrites     │
                    │ model name   │
                    └──────────────┘
```

---

## Credits

Discovered during the [Squad](https://github.com/bradygaster/squad) airplane mode experiment.
Issue: [tamirdresher/tamresearch1#2173](https://github.com/tamirdresher/tamresearch1/issues/2173)

## License

MIT
